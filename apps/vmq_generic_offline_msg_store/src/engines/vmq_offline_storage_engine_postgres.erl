-module(vmq_offline_storage_engine_postgres).

-export([open/1, close/1, write/4, delete/2, delete/3, find/2]).

-include_lib("vmq_commons/src/vmq_types_common.hrl").

-define(TABLE, "messages").

% API
open(Opts) ->
    epgsql:connect(Opts).

write(Client, SIdB, MsgRef, MsgB) ->
    epgsql:equery(Client,
                  "INSERT INTO " ++ ?TABLE ++ " (sid, msgref, payload) VALUES ($1, $2, $3)",
                  [SIdB, MsgRef, MsgB]
                 ).

delete(Client, SIdB) ->
    epgsql:equery(Client, "DELETE FROM " ++ ?TABLE ++ " WHERE sid=$1", [SIdB]).

delete(Client, SIdB, MsgRef) ->
    epgsql:equery(Client, "DELETE FROM " ++ ?TABLE ++ " WHERE sid=$1 AND msgref=$2", [SIdB, MsgRef]).

find(Client, SIdB) ->
    case epgsql:equery(Client, "SELECT payload FROM " ++ ?TABLE ++ " WHERE sid=$1", [SIdB]) of
        {ok, _, MsgsInB} ->
            DMsgs = lists:foldr(fun({MsgB}, Acc) ->
            Msg = binary_to_term(MsgB),
            D = #deliver{msg = Msg, qos = Msg#vmq_msg.qos},
            [D | Acc] end, [], MsgsInB),
            {ok, DMsgs};
        Res -> Res
    end.

close(Client) ->
    epgsql:close(Client).
