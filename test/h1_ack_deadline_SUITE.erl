-module(h1_ack_deadline_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([accepted_tcp/1, accepted_tls/1, healthy_quiet_stream/1]).

all() -> [accepted_tcp, accepted_tls, healthy_quiet_stream].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(h1),
    Config.

end_per_suite(_Config) ->
    application:stop(h1),
    ok.

accepted_tcp(_Config) ->
    accepted(gen_tcp, #{}).

accepted_tls(Config) ->
    case os:find_executable("openssl") of
        false -> {skip, "openssl unavailable"};
        _ ->
            Cert = filename:join(?config(priv_dir, Config), "cert.pem"),
            Key = filename:join(?config(priv_dir, Config), "key.pem"),
            _ = os:cmd(lists:flatten(io_lib:format(
                "openssl req -x509 -newkey rsa:2048 -keyout ~s -out ~s "
                "-days 1 -nodes -subj '/CN=localhost' 2>/dev/null", [Key, Cert]))),
            accepted(ssl, #{transport => ssl, cert => Cert, key => Key})
    end.

accepted(Transport, Extra) ->
    Parent = self(),
    Handler = fun(Conn, Id, _, _, _) ->
        {ok, Transport, Socket, _} = h1:accept_connect(Conn, Id, []),
        Result = case os:type() of
            {unix, linux} -> getopts(Transport, Socket, [{raw, 6, 18, 4}]);
            _ -> getopts(Transport, Socket, [nodelay])
        end,
        Parent ! {options, Result},
        close(Transport, Socket)
    end,
    {ok, Ref} = h1:start_server(0, Extra#{handler => Handler}),
    try
        {ok, Peer} = connect(Transport, h1:server_port(Ref)),
        try
            ok = send(Transport, Peer,
                <<"CONNECT example.com:443 HTTP/1.1\r\nhost: example.com:443\r\n\r\n">>),
            receive
                {options, Options} ->
                    Expected = case os:type() of
                        {unix, linux} -> {ok, [{raw, 6, 18, <<20000:32/native-unsigned-integer>>}]};
                        _ -> {ok, [{nodelay, true}]}
                    end,
                    ?assertEqual(Expected, Options)
            after 5000 -> ct:fail(no_socket_options)
            end
        after close(Transport, Peer) end
    after h1:stop_server(Ref) end.

healthy_quiet_stream(_Config) ->
    Parent = self(),
    Handler = fun(Conn, Id, _, _, _) ->
        ok = h1:send_response(Conn, Id, 200, []),
        ok = h1:send_data(Conn, Id, <<"ready">>, false),
        Parent ! {stream, self()},
        receive finish -> h1:send_data(Conn, Id, <<"done">>, true)
        after 30000 -> error(stream_not_finished)
        end
    end,
    {ok, Ref} = h1:start_server(0, #{handler => Handler, idle_timeout => 100}),
    try
        {ok, Peer} = h1:connect("127.0.0.1", h1:server_port(Ref),
            #{transport => tcp, request_timeout => infinity, idle_timeout => infinity}),
        try
            {ok, Id} = h1:request(Peer, <<"GET">>, <<"/">>, [{<<"host">>, <<"x">>}]),
            receive {h1, Peer, {response, Id, 200, _}} -> ok
            after 5000 -> ct:fail(no_response) end,
            receive {h1, Peer, {data, Id, <<"ready">>, false}} -> ok
            after 5000 -> ct:fail(no_initial_data) end,
            receive {h1, Peer, {closed, Reason}} -> ct:fail({healthy_peer_closed, Reason})
            after 21000 -> ok end,
            receive {stream, HandlerPid} -> HandlerPid ! finish
            after 1000 -> ct:fail(no_handler) end,
            receive {h1, Peer, {data, Id, <<"done">>, _}} -> ok
            after 5000 -> ct:fail(no_final_data) end
        after h1:close(Peer) end
    after h1:stop_server(Ref) end.

getopts(gen_tcp, Socket, Opts) -> inet:getopts(Socket, Opts);
getopts(ssl, Socket, Opts) -> ssl:getopts(Socket, Opts).

connect(gen_tcp, Port) -> gen_tcp:connect({127,0,0,1}, Port, [binary, {active, false}]);
connect(ssl, Port) -> ssl:connect("localhost", Port, [binary, {active, false}, {verify, verify_none}]).

send(gen_tcp, Socket, Data) -> gen_tcp:send(Socket, Data);
send(ssl, Socket, Data) -> ssl:send(Socket, Data).

close(gen_tcp, Socket) -> gen_tcp:close(Socket);
close(ssl, Socket) -> ssl:close(Socket).
