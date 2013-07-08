-module(echo_handler).

-export([init/3]).

init(Transport, Socket, _Opts) ->
    wait_request(Transport, Socket).

wait_request(Transport, Socket) ->
    case  Transport:recv(Socket, 0, 5000) of
        {ok, <<".\r\n">>} ->
            io:format("remote exited", []),
            Transport:close(Socket);
        {ok, Data} ->
            io:format("got ~p~n", [Data]),
            Transport:send(Socket, Data),
            wait_request(Transport, Socket);
        {error, _Reason} ->
            Transport:close(Socket)
    end.
