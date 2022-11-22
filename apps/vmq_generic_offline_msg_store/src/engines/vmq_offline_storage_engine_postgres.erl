-module(vmq_offline_storage_engine_postgres).

-export([open/1, close/1, write/5, delete/3, delete/4, read/4, find/3]).

-include_lib("vmq_commons/src/vmq_types_common.hrl").

-define(TABLE, "messages").

-dialyzer([{nowarn_function, [write/5, delete/3, delete/4, read/4, find/3, equery/4]}]).

-record(column, {
    name :: binary(),
    type :: epgsql:epgsql_type(),
    oid :: integer(),
    size :: -1 | pos_integer(),
    modifier :: -1 | pos_integer(),
    format :: integer()
}).

-record(statement, {
    name :: string(),
    columns :: [#column{}],
    types :: [epgsql:epgsql_type()],
    parameter_info :: [epgsql_oid_db:oid_entry()]
}).

% API
open(Opts) ->
    epgsql:connect(Opts).

write(Client, SIdB, MsgRef, MsgB, Timeout) ->
    equery(Client,
           "INSERT INTO " ++ ?TABLE ++ " (sid, msgref, payload) VALUES ($1, $2, $3)",
           [SIdB, MsgRef, MsgB],
           Timeout
          ).

delete(Client, SIdB, Timeout) ->
    equery(Client, "DELETE FROM " ++ ?TABLE ++ " WHERE sid=$1", [SIdB], Timeout).

delete(Client, SIdB, MsgRef, Timeout) ->
    equery(Client, "DELETE FROM " ++ ?TABLE ++ " WHERE sid=$1 AND msgref=$2", [SIdB, MsgRef], Timeout).

read(Client, SIdB, MsgRef, Timeout) ->
    case equery(Client, "SELECT payload FROM " ++ ?TABLE ++ " WHERE sid=$1 AND msgref=$2", [SIdB, MsgRef], Timeout) of
        {ok, _, [{BinaryMsg}]} -> {ok, binary_to_term(BinaryMsg)};
        E -> E
    end.

find(Client, SIdB, Timeout) ->
    case equery(Client, "SELECT payload FROM " ++ ?TABLE ++ " WHERE sid=$1 ORDER BY created_time ASC", [SIdB], Timeout) of
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

equery(C, SQL, Parameters, Timeout) ->
    Ref0 = epgsqla:parse(C, SQL),
    receive
        {C, Ref0, {ok, #statement{types = Types} = S}} ->
            TypedParameters = lists:zip(Types, Parameters),
            Ref1 = epgsqla:equery(C, S, TypedParameters),
            receive
                {C, Ref1, Result} -> Result
            after Timeout ->
                ok = epgsql:cancel(C),
                receive
                    {C, Ref1, Result} -> Result
                end
            end;
        {C, Ref0, Result} -> Result
    after Timeout ->
        ok = epgsql:cancel(C),
        receive
            {C, Ref0, Result} -> Result
        end
    end.
