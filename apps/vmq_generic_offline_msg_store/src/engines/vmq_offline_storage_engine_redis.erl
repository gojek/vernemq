-module(vmq_offline_storage_engine_redis).

-export([open/1, close/1, write/6, delete/4, delete/5, read/5, find/4]).

-include_lib("vmq_server/src/vmq_server.hrl").

-dialyzer([{nowarn_function, [write/6, delete/4, delete/5, read/5, find/4]}]).

% API
open(Opts) ->
    Username = case proplists:get_value(username, Opts, undefined) of
                    undefined -> undefined;
                    User when is_atom(User) -> atom_to_list(User)
                end,
    Password = case proplists:get_value(password, Opts, undefined) of
                    undefined -> undefined;
                    Pass when is_atom(Pass) -> atom_to_list(Pass)
                end,
    {Database, _} = string:to_integer(proplists:get_value(database, Opts, "2")),
    Port = proplists:get_value(port, Opts, 26379),
    SentinelHosts = vmq_schema_util:parse_list(proplists:get_value(host, Opts, "[\"localhost\"]")),
    SentinelEndpoints = lists:foldr(fun(Host, Acc) -> [{Host, Port} | Acc]end, [], SentinelHosts),
    ConnectOpts = [{sentinel, [{endpoints, SentinelEndpoints},
                               {timeout, proplists:get_value(connect_timeout, Opts, 5000)}]
                    },
                   {username, Username},
                   {password, Password},
                   {database, Database}],
    eredis:start_link(ConnectOpts).

write(Client, SIdB, _MsgRef, MsgB, Ts1, Timeout) ->
    Ts2 = vmq_util:ts(),
    Val = Ts2 - Ts1,
    vmq_metrics:pretimed_measurement({vmq_offline_msg_store, write_queue}, Val),
    vmq_redis:query(Client, ["RPUSH", SIdB, MsgB], ?RPUSH, ?MSG_STORE_WRITE, Timeout).

delete(Client, SIdB, Ts1, Timeout) ->
    Ts2 = vmq_util:ts(),
    Val = Ts2 - Ts1,
    vmq_metrics:pretimed_measurement({vmq_offline_msg_store, delete_all_queue}, Val),
    vmq_redis:query(Client, ["DEL", SIdB], ?DEL, ?MSG_STORE_DELETE, Timeout).

delete(Client, SIdB, _MsgRef, Ts1, Timeout) ->
    Ts2 = vmq_util:ts(),
    Val = Ts2 - Ts1,
    vmq_metrics:pretimed_measurement({vmq_offline_msg_store, delete_queue}, Val),
    vmq_redis:query(Client, ["LPOP", SIdB, 1], ?LPOP, ?MSG_STORE_DELETE, Timeout).

read(_Client, _SIdB, _MsgRef, Ts1, _Timeout) ->
    Ts2 = vmq_util:ts(),
    Val = Ts2 - Ts1,
    vmq_metrics:pretimed_measurement({vmq_offline_msg_store, read_queue}, Val),
    {error, not_supported}.

find(Client, SIdB, Ts1, Timeout) ->
    Ts2 = vmq_util:ts(),
    Val = Ts2 - Ts1,
    vmq_metrics:pretimed_measurement({vmq_offline_msg_store, find_queue}, Val),
    case vmq_redis:query(Client, ["LRANGE", SIdB, "0", "-1"], ?FIND, ?MSG_STORE_FIND, Timeout) of
        {ok, MsgsInB} ->
            DMsgs = lists:foldr(fun(MsgB, Acc) ->
            Msg = binary_to_term(MsgB),
            D = #deliver{msg = Msg, qos = Msg#vmq_msg.qos},
            [D | Acc] end, [], MsgsInB),
            {ok, DMsgs};
        Res -> Res
    end.

close(Client) ->
    eredis:stop(Client).
