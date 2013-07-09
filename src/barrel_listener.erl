%%% -*- erlang -*-
%%%
%%% This file is part of barrel released under the MIT license.
%%% See the NOTICE for more information.

-module(barrel_listener).
-behaviour(gen_server).

-export([get_port/1,
         info/1, info/2]).


-export([start_link/1]).


%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         code_change/3, terminate/2]).


-record(state, {socket,
                transport,
                transport_opts,
                nb_acceptors,
                acceptors = [],
                reqs,
                open_reqs,
                listener_opts,
                protocol}).


get_port(Ref) ->
    gen_server:call(Ref, get_port).

info(Ref) ->
    info(Ref, [ip, port, open_reqs, nb_acceptors]).

info(Ref, Keys) ->
    gen_server:call(Ref, {info, Keys}).


start_link([_, _, _, _, _, ListenerOpts] = Options) ->
    Ref = proplists:get_value(ref, ListenerOpts),
    case gen_server:start_link({local, Ref}, ?MODULE, Options, []) of
        {ok, Pid} ->
            ok = barrel_server:set_listener(Ref, Pid),
            {ok, Pid};
        Error ->
            Error
    end.

init([NbAcceptors, Transport, TransOpts, Protocol, ProtoOpts,
      ListenerOpts]) ->

    process_flag(trap_exit, true),

    {ok, Socket} = Transport:listen(TransOpts),

    %% launch acceptors
    Acceptors = [barrel_acceptor:start_link(self(), Transport, Socket,
                                            ListenerOpts,
                                            {Protocol, ProtoOpts})
                 || _ <- lists:seq(1, NbAcceptors)],
    {ok, #state{socket = Socket,
                transport = Transport,
                transport_opts = TransOpts,
                acceptors = Acceptors,
                nb_acceptors = NbAcceptors,
                reqs = gb_trees:empty(),
                open_reqs = 0,
                listener_opts = ListenerOpts,
                protocol = {Protocol, ProtoOpts}}}.


handle_call(get_port, _From, #state{socket=S, transport=Transport}=State) ->
    case Transport:sockname(S) of
        {ok, {_, Port}} ->
            {reply, {ok, Port}, State};
        Error ->
            {reply, Error, State}
    end;

handle_call({info, Keys}, _From, State) ->
    Infos = get_infos(Keys, State),
    {reply, Infos, State};

handle_call(_Msg, _From, State) ->
    {reply, ok, State}.

handle_cast({accepted, Pid}, State) ->
    %% accept a request and start a new acceptor
    NewState = start_new_acceptor(accept_request(Pid, State)),
    {noreply, NewState};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'DOWN', _MRef, _, Pid, _}, #state{reqs=Reqs}=State) ->
    {noreply, State#state{reqs=gb_trees:delete_any(Pid, Reqs)}};

handle_info({'EXIT', _Pid, {error, emfile}}, State) ->
    error_logger:error_msg("No more file descriptors, shutting down:
                           ~p~n", [?MODULE]),
    {stop, emfile, State};

handle_info({'EXIT', Pid, normal}, State) ->
    {noreply, remove_acceptor(State, Pid)};

handle_info({'EXIT', Pid, Reason}, State) ->
    error_logger:info_msg("request (pid ~p) unexpectedly crashed:~n~p~n",
                [Pid, Reason]),
    {noreply, remove_acceptor(State, Pid)}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%% internals
%%
accept_request(Pid, #state{reqs=Reqs, acceptors=Acceptors}=State) ->
    %% remove acceptor from the list of acceptor and increase state
    unlink(Pid),

    %% trap premature exit
    receive
        {'EXIT', Pid, _} ->
            true
    after 0 ->
            true
    end,

    MRef = erlang:monitor(process, Pid),
    NewReqs = gb_trees:enter(Pid, MRef, Reqs),
    State#state{reqs=NewReqs, acceptors=lists:delete(Pid, Acceptors)}.

remove_acceptor(#state{acceptors=Acceptors, nb_acceptors=N}=State, Pid)
        when length(Acceptors) < N->
    NewPid = barrel_acceptor:start_link(self(), State#state.transport,
                                        State#state.socket,
                                        State#state.listener_opts,
                                        State#state.protocol),
    Acceptors1 = [NewPid | lists:delete(Pid, Acceptors)],
    State#state{acceptors = Acceptors1};
remove_acceptor(State, Pid) ->
    State#state{acceptors = lists:delete(Pid, State#state.acceptors)}.

start_new_acceptor(State) ->
    Pid = barrel_acceptor:start_link(self(), State#state.transport,
                                     State#state.socket,
                                     State#state.listener_opts,
                                     State#state.protocol),

    State#state{acceptors = [Pid | State#state.acceptors]}.

get_infos(Keys, #state{transport=Transport, socket=Socket}=State) ->
    IpPort = case Transport:sockname(Socket) of
        {ok, IpPort1} ->
            IpPort1;
        Error ->
            {{error, Error}, {error, Error}}
    end,
    get_infos(Keys, IpPort, State, []).

get_infos([], _IpPort, _State, Acc) ->
    lists:reverse(Acc);
get_infos([ip|Rest], {Ip, _}=IpPort, State, Acc) ->
    get_infos(Rest, IpPort, State, [{ip, Ip}|Acc]);
get_infos([port|Rest], {_, Port}=IpPort, State, Acc) ->
    get_infos(Rest, IpPort, State, [{port, Port}|Acc]);
get_infos([open_reqs|Rest], IpPort, #state{reqs=Reqs}=State, Acc) ->
    get_infos(Rest, IpPort, State, [{open_reqs, gb_trees:size(Reqs)}|Acc]);
get_infos([nb_acceptors|Rest], IpPort, #state{acceptors=Acceptors}=State,
         Acc) ->
    get_infos(Rest, IpPort, State, [{acceptors, length(Acceptors)}|Acc]).
