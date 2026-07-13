-module(vmq_statsd).

-export([
    counter/2,
    gauge/2
]).

-define(DEFAULT_HOST, "127.0.0.1").
-define(DEFAULT_PORT, 9125).
-define(DEFAULT_PREFIX, "vernemq").

%% @doc Emit a statsd counter (`name:Value|c').
-spec counter(iodata(), integer()) -> ok.
counter(Name, Value) ->
    send(Name, Value, "c").

%% @doc Emit a statsd gauge (`name:Value|g').
-spec gauge(iodata(), integer()) -> ok.
gauge(Name, Value) ->
    send(Name, Value, "g").

send(Name, Value, Type) ->
    try
        Host = application:get_env(vmq_server, statsd_host, ?DEFAULT_HOST),
        Port = application:get_env(vmq_server, statsd_port, ?DEFAULT_PORT),
        Line = [metric_name(Name), $:, integer_to_list(Value), $|, Type],
        {ok, Socket} = gen_udp:open(0, [{active, false}]),
        try
            _ = gen_udp:send(Socket, host(Host), Port, Line)
        after
            gen_udp:close(Socket)
        end,
        ok
    catch
        _:_ ->
            ok
    end.

metric_name(Name) ->
    Prefix = application:get_env(vmq_server, statsd_prefix, ?DEFAULT_PREFIX),
    Node = sanitize(atom_to_list(node())),
    [Prefix, $., Node, $., Name].

sanitize(Str) ->
    [
        case C of
            $. -> $_;
            $@ -> $_;
            $: -> $_;
            _ -> C
        end
     || C <- Str
    ].

host(Host) when is_list(Host) ->
    case inet:parse_address(Host) of
        {ok, Addr} -> Addr;
        _ -> Host
    end;
host(Host) ->
    Host.
