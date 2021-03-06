%% Start a server to listen on port 1080, which later will establish connection from  SOCKS client

%% TODO Support authentication (It doesn't require any authentication now)
%% TODO Support UDP
%% TODO Support Bind

-module(gfw_socks).
-export([start/0]).
-import(error_logger,[info_msg/1,info_msg/2,error_msg/1,error_msg/2]).

-define(INIT, init).
-define(HELLO, hello).
-define(CONNECTED, connected).
-define(STOP, stop).
-define(CONNECTION_TIMEOUT, 20000).
-define(CACHE_EXPIRED,3600).
-define(CACHE_GET, 'get').
-define(CACHE_SAVE, save).
-define(CACHE_REMOVE, remove).

-type state() :: init|hello|connected.

-spec loop(LocalSocket, State, RemoteSocket) -> any() when
    LocalSocket :: gen_tcp:socket(),
    State :: state(),
    RemoteSocket :: gen_tcp:socket().

-spec handle_connection_request(LocalSocket, RemoteSocket, State, Packet) -> {state(),gen_tcp:socket()} when
    LocalSocket :: gen_tcp:socket(),
    RemoteSocket :: gen_tcp:socket(),
    State :: state(),
    Packet :: binary().

start() ->
    {ok,[{server_port, Port,_,_,_,_}]} = file:consult("gfw_socks.config"),
    start_socks(Port).

start_socks(Port) ->
    init(),
    {Result, Listen} = gen_tcp:listen(Port,[binary,{active,false},{packet,0},{reuseaddr,true}, {send_timeout,?CONNECTION_TIMEOUT}]),
    case Result of
        ok ->  new_connection(Listen);
        error -> error_msg("ERROR, failed to listen on port ~p as ~p",[Port,Listen])
    end.

%% Initialize the Host to IP cache
init() ->
    Pid = spawn(fun() -> ip_cache(#{}) end),
    register(cache, Pid).

new_connection(Listen) ->
    {Result, Socket} = gen_tcp:accept(Listen),
    case Result of
        ok -> 
            spawn(fun() -> loop(Socket, ?INIT, undefined) end);
        error ->
            error_msg("Failed to accept a connection , Reason = ~p~n", Socket)
    end,
    new_connection(Listen).

%%The main loop for a single local socket
loop(LS, ST, RS) ->
    {Result, Packet} = gen_tcp:recv(LS, 0, infinity),
    case Result of
        ok -> 
            {State, RemoteSocket} = handle_connection_request(LS, RS, ST, Packet),
            case State of
                ?STOP -> close_local_socket(LS);
                _Any -> loop(LS, State, RemoteSocket)
            end;
        error -> 
            close_local_socket(LS),
            case Packet of
                closed -> ok;
                _Any -> error_msg("loop, Reason = ~p~n",[Packet])
            end
    end.

handle_connection_request(LS, RS, ST, Packet) ->
    P = trs_packet(Packet),
    case ST of
        ?INIT      -> handle_init_request(LS, P);
        ?HELLO     -> handle_hello_request(LS, P);
        ?CONNECTED -> handle_reply_request(RS, P)
    end.

handle_init_request(LS, Packet) ->
    <<Version:1/binary,_/binary>> = Packet,
    case Version of
        %%Only support socks5 now
        <<5>> -> 
            send_packet(LS, <<5, 0>>),
            {?HELLO, undefined};
        _Any -> {?STOP, undefined}
    end.

handle_hello_request(LS, Packet) ->
    %%fetch the remote addr and remote port from the data.
    send_packet(LS, <<5,0,0,1,0,0,0,0,16,16>>),
    {Addr, Port} = parse_destination_addr(Packet),
    info_msg("Start to listen on ~p : ~p~n",[Addr,trs_port(Port)]),
    {Result, RS} = gen_tcp:connect(Addr, trs_port(Port),[binary, {active,false}, {packet,0},{send_timeout, ?CONNECTION_TIMEOUT}], ?CONNECTION_TIMEOUT),
    case Result of
        ok ->
            spawn(fun() -> handle_remote_data(RS, LS) end),
            {?CONNECTED, RS};
        error ->
            %%Do we need to reconnect?
            error_msg("Remote serve unreachable, Addr = ~p, Port = ~p, Reason = ~p~n",[Addr, Port, RS]),
            {?STOP, undefined}
    end.

handle_reply_request(RS, Packet) ->
    send_packet(RS, Packet), 
    {?CONNECTED, RS}. 

handle_remote_data(RS, LS) ->
    Addr = inet:peername(RS),
    {Result, Packet} = gen_tcp:recv(RS,0,infinity),
    case Result of
        ok -> 
            send_to_local(LS, Packet),
            handle_remote_data(RS, LS);
        error -> 
            gen_tcp:close(RS),
            close_local_socket(LS),
            case Packet of
                closed -> ok;
                _Any -> error_msg("Failed to retrieve data from remote ~p, Reason = ~p~n",[Addr,Packet])
            end
    end.

close_local_socket(LS) ->
    Pid = get(LS),
    case Pid of
        undefined ->
            gen_tcp:close(LS),
            ok;
        _Any ->
            Pid ! {close, LS}
    end.


%% When the proxy retrive data from the remote,  send the data to the local socket.
%% Implement a queue to send the data sequentially.
%% NOTICE, when the local socket is close, remove related process.
send_to_local(LS, Packet) ->
    Pid = get(LS),
    if 
        Pid == undefined ->
            Npid = spawn(fun() -> async_send_to_local() end),
            put(LS, Npid),
            Npid ! {ok, LS, Packet};
        true ->
            Pid ! {ok, LS, Packet}
    end.

async_send_to_local() ->
    receive
        {ok, LS, Packet} -> 
            send_packet(LS, Packet),
            async_send_to_local();
        {close, LS} -> 
            gen_tcp:close(LS),
            close;
        _Any ->
            close
    end.


send_packet(Socket,Packet) ->
    gen_tcp:send(Socket,Packet).


parse_destination_addr(Packet) ->
    <<_:3/binary,T,_/binary>> = Packet,
    case T of
       16#01 -> 
            <<_:3/binary,T,Addr:4/binary,Port:2/binary>> = Packet, 
            {list_to_tuple(Addr), Port};
       16#03 ->
            <<_:3/binary,T,N,URL:N/binary,Port:2/binary>> = Packet,
            {url_to_ip(binary_to_list(URL)), Port};
       16#04 ->
            <<_:3/binary,T,Addr:16/binary,Port:2/binary>> = Packet,
            {list_to_tuple(Addr), Port}
    end.

url_to_ip(URL) ->
    IP = get_ip(URL),
    case IP of
        undefined ->
            {S,{hostent,_,_,_,_,Addrs}} = inet:gethostbyname(URL),
            case S of
                ok ->
                    [Addr|_] = Addrs,
                    store_ip(URL, Addr),
                    Addr;
                error ->
                    error_msg("Failed to get ip address, URL = ~p",[URL]),
                    {{},0}
            end;
        IP -> IP
    end.


trs_port(Port) ->
    <<H1,H2>> = Port,
    H1 * 256 + H2.


ip_cache(IP_map) ->
    receive
        {?CACHE_GET,Host, Pid} -> 
            IP = maps:get(Host,IP_map,undefined),
            Pid ! {self(), IP},
            ip_cache(IP_map);
        {?CACHE_SAVE, Host} ->
            M2 = maps:remove(Host, IP_map),
            ip_cache(M2);
        {?CACHE_SAVE, Host, IP} ->
            M2 = maps:put(Host,{IP, tis()},IP_map),
            ip_cache(M2)
    end.

store_ip(Host, IP) ->
    Pid = whereis(cache),
    Pid ! {?CACHE_SAVE,Host, IP}.

get_ip(Host) ->
    Pid = whereis(cache),
    Pid ! {?CACHE_GET, Host , self()},
    receive
        {Pid,undefined} -> undefined;
        {Pid, {IP, Time}} ->
            CurrentTime = tis(),
            if 
                CurrentTime - Time > ?CACHE_EXPIRED ->
                    Pid ! {?CACHE_REMOVE, Host},
                    undefined;
               true -> IP
            end;
        _Any -> error_msg("error here ~p~n",[_Any])
    end.

tis() ->
    calendar:datetime_to_gregorian_seconds(calendar:local_time()).

trs_packet(Packet) ->
    << <<bnot X>> || <<X>> <= Packet >>.
