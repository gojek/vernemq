-module(vmq_redis).
-author("dhruvjain").

-include("vmq_server.hrl").

%% API
-export([query/4, pipelined_query/3]).

query(Client, QueryCmd, Cmd, Operation) ->
    vmq_metrics:incr_redis_cmd({Cmd, Operation}),
    V1 = vmq_util:ts(),
    Result = case eredis:q(whereis(Client), QueryCmd) of
                 {error, <<"ERR stale_request">>} = Res when Cmd == ?FCALL ->
                     vmq_metrics:incr_redis_stale_cmd({Cmd, Operation}),
                     lager:error("Cannot ~p due to staleness", [Cmd]),
                     Res;
                 {error, <<"ERR unauthorized">>} = Res when Cmd == ?FCALL ->
                     vmq_metrics:incr_unauth_redis_cmd({Cmd, Operation}),
                     lager:error("Cannot ~p as client is connected on different node", [Cmd]),
                     Res;
                 {error, Reason} ->
                     vmq_metrics:incr_redis_cmd_err({Cmd, Operation}),
                     lager:error("Cannot ~p due to ~p", [Cmd, Reason]),
                     {error, Reason};
                 {ok, undefined} ->
                     vmq_metrics:incr_redis_cmd_miss({Cmd, Operation}),
                     {ok, undefined};
                 {ok, []} ->
                     vmq_metrics:incr_redis_cmd_miss({Cmd, Operation}),
                     {ok, []};
                 Res -> Res
             end,
    vmq_metrics:pretimed_measurement({redis_cmd,
        run,
        [{cmd, Cmd},
            {operation, Operation}
        ]}, vmq_util:ts() - V1),
    Result.

pipelined_query(Client, QueryList, Operation) ->
    [_ | PipelinedCmd] = lists:foldl(fun([Cmd | _], Acc) -> "|" ++ atom_to_list(Cmd) ++ Acc end, "", QueryList),
    vmq_metrics:incr_redis_cmd({?PIPELINE, Operation}),
    V1 = vmq_util:ts(),
    Result = case eredis:qp(whereis(Client), QueryList) of
                 {error, no_connection} ->
                     lager:error("No connection with Redis"),
                     {error, no_connection};
                 Res -> Res
             end,
    IsErrPresent = lists:foldl(fun ({ok, _}, Acc) -> Acc;
        ({error, Reason}, _Acc) ->
            lager:error("Cannot ~p due to ~p", [PipelinedCmd, Reason]),
            true
                               end, false, Result),
    if IsErrPresent -> vmq_metrics:incr_redis_cmd_err({?PIPELINE, Operation});
        true -> ok
    end,
    vmq_metrics:pretimed_measurement({redis_cmd, run, [{cmd, PipelinedCmd}, {operation, Operation}]}, vmq_util:ts() - V1),
    Result.
