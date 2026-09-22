-module(vmq_events_sidecar_metrics).
-include("../include/vmq_events_sidecar.hrl").

-behaviour(gen_server).

-export([
    start_link/0,
    metrics/0,
    incr_sidecar_events/1,
    incr_sidecar_events_error/1,
    incr_events_sampled/2,
    incr_events_dropped/2,
    incr_grpc_call_result/2,
    incr_grpc_worker_crashed/0,
    incr_grpc_events_lost/1,
    incr_grpc_connects/1,
    incr_grpc_connections_recycled/0
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-define(SERVER, ?MODULE).

-define(SIDECAR_EVENTS, sidecar_events).
-define(SIDECAR_EVENTS_ERROR, sidecar_events_error).
-define(GRPC_WORKER_CRASHED, grpc_worker_crashed).
-define(GRPC_EVENTS_LOST, grpc_events_lost).
-define(GRPC_CONNECTS, grpc_connects).
-define(GRPC_CONNECTIONS_RECYCLED, grpc_connections_recycled).
-define(EVENTS_SAMPLING_TABLE, vmq_events_sidecar_events_sampling).
-define(GRPC_CALL_RESULTS_TABLE, vmq_events_sidecar_grpc_call_results).

-define(ON_REGISTER, on_register).
-define(ON_REGISTER_FAILED, on_register_failed).
-define(ON_PUBLISH, on_publish).
-define(ON_SUBSCRIBE, on_subscribe).
-define(ON_UNSUBSCRIBE, on_unsubscribe).
-define(ON_DELIVER, on_deliver).
-define(ON_DELIVERY_COMPLETE, on_delivery_complete).
-define(ON_OFFLINE_MESSAGE, on_offline_message).
-define(ON_CLIENT_WAKEUP, on_client_wakeup).
-define(ON_CLIENT_OFFLINE, on_client_offline).
-define(ON_CLIENT_GONE, on_client_gone).
-define(ON_SESSION_EXPIRED, on_session_expired).
-define(ON_MESSAGE_DROP, on_message_drop).

-record(state, {}).
-record(metric_def, {
    type :: atom(),
    labels :: [metric_label()],
    id :: metric_id(),
    name :: atom(),
    description :: undefined | binary()
}).

-type metric_def() :: #metric_def{}.
-type metric_label() :: {atom(), string()}.
-type metric_id() ::
    atom()
    | {atom(), non_neg_integer() | atom()}
    | {atom(), atom(), atom()}
    | [{atom(), [{atom(), any()}]}].

%%%===================================================================
%%% API
%%%===================================================================

-spec start_link() -> 'ignore' | {'error', _} | {'ok', pid()}.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-spec metrics() -> [{metric_def(), non_neg_integer()}].
metrics() ->
    MetricDefs = metrics_defs(),
    IdDef = lists:foldl(
        fun(#metric_def{id = Id} = MD, Acc) ->
            maps:put(Id, MD, Acc)
        end,
        #{},
        MetricDefs
    ),
    lists:filtermap(
        fun(#metric_def{id = Id}) ->
            Val =
                try
                    counter_val(Id)
                catch
                    _:_ -> 0
                end,
            case maps:find(Id, IdDef) of
                {ok, #metric_def{
                    type = Type,
                    labels = Labels,
                    name = Name,
                    description = Description
                }} ->
                    {true, {Type, Labels, Id, Name, Description, Val}};
                error ->
                    lager:warning("unknown metrics id: ~p", [Id]),
                    false
            end
        end,
        MetricDefs
    ) ++ events_sampling_metrics() ++ grpc_call_result_metrics() ++ grpc_worker_queue_metrics() ++
        grpc_connection_metrics().

-spec incr_sidecar_events(atom()) -> ok.
incr_sidecar_events(HookName) ->
    incr_item({?SIDECAR_EVENTS, HookName}, 1).

-spec incr_sidecar_events_error(atom()) -> ok.
incr_sidecar_events_error(HookName) ->
    incr_item({?SIDECAR_EVENTS_ERROR, HookName}, 1).

-spec incr_events_sampled(atom(), binary() | undefined) -> ok.
incr_events_sampled(_, undefined) ->
    ok;
incr_events_sampled(HookName, Criterion) ->
    incr_events_sampled_item(HookName, Criterion, sampled).

-spec incr_events_dropped(atom(), binary() | undefined) -> ok.
incr_events_dropped(_, undefined) ->
    ok;
incr_events_dropped(HookName, Criterion) ->
    incr_events_sampled_item(HookName, Criterion, dropped).

-spec incr_grpc_worker_crashed() -> ok.
incr_grpc_worker_crashed() ->
    incr_item(?GRPC_WORKER_CRASHED, 1).

-spec incr_grpc_events_lost(pos_integer()) -> ok.
incr_grpc_events_lost(Count) ->
    incr_item(?GRPC_EVENTS_LOST, Count).

-spec incr_grpc_connects(pos_integer()) -> ok.
incr_grpc_connects(Count) ->
    incr_item(?GRPC_CONNECTS, Count).

-spec incr_grpc_connections_recycled() -> ok.
incr_grpc_connections_recycled() ->
    incr_item(?GRPC_CONNECTIONS_RECYCLED, 1).

-spec incr_grpc_call_result(atom(), atom()) -> ok.
incr_grpc_call_result(HookName, Reason) ->
    try
        ets:update_counter(?GRPC_CALL_RESULTS_TABLE, {HookName, Reason}, 1)
    catch
        _:_ ->
            try
                ets:insert_new(?GRPC_CALL_RESULTS_TABLE, {{HookName, Reason}, 0}),
                incr_grpc_call_result(HookName, Reason)
            catch
                _:_ ->
                    lager:warning("couldn't initialize grpc call errors table", [])
            end
    end,
    ok.

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

-spec init(_) -> {ok, #state{}}.
init([]) ->
    AllEntries = [Id || #metric_def{id = Id} <- metrics_defs()],
    NumEntries = length(AllEntries),
    Idxs = lists:map(fun(Id) -> met2idx(Id) end, AllEntries),
    NumEntries = length(lists:sort(Idxs)),
    NumEntries = length(lists:usort(Idxs)),

    ets:new(?EVENTS_SAMPLING_TABLE, [named_table, public, {write_concurrency, true}]),
    ets:new(?GRPC_CALL_RESULTS_TABLE, [named_table, public, {write_concurrency, true}]),

    case catch persistent_term:get(?MODULE) of
        {'EXIT', {badarg, _}} ->
            ARef = atomics:new(2 * NumEntries, [{signed, false}]),
            persistent_term:put(?MODULE, ARef);
        _ExistingRef ->
            ok
    end,
    {ok, #state{}}.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

incr_item(_, 0) ->
    ok;
incr_item(Entry, Val) when Val > 0 ->
    ARef =
        case get(vmq_events_sidecar_metrics_atomics_ref) of
            undefined ->
                Ref = persistent_term:get(?MODULE),
                put(vmq_events_sidecar_metrics_atomics_ref, Ref),
                Ref;
            Ref ->
                Ref
        end,
    atomics:add(ARef, met2idx(Entry), Val).

counter_val(Entry) ->
    ARef = persistent_term:get(?MODULE),
    atomics:get(ARef, met2idx(Entry)).

incr_events_sampled_item(HookName, Criterion, Type) ->
    try
        ets:update_counter(?EVENTS_SAMPLING_TABLE, {HookName, Criterion, Type}, 1)
    catch
        _:_ ->
            try
                ets:insert_new(?EVENTS_SAMPLING_TABLE, {{HookName, Criterion, Type}, 0}),
                incr_events_sampled_item(HookName, Criterion, Type)
            catch
                _:_ ->
                    lager:warning("couldn't initialize sidecar metrics tables", [])
            end
    end,
    ok.

events_sampling_metrics() ->
    ets:foldl(
        fun({{HookName, Criterion, Type}, TotalCount}, Acc) ->
            [
                {counter, sampling_metric_labels(HookName, Criterion),
                    sampling_metric_id(HookName, Criterion, Type), sampling_metric_name(Type),
                    sampling_metric_description(Type), TotalCount}
                | Acc
            ]
        end,
        [],
        ?EVENTS_SAMPLING_TABLE
    ).

sampling_metric_name(sampled) ->
    vmq_events_sampled;
sampling_metric_name(dropped) ->
    vmq_events_dropped.

sampling_metric_description(sampled) ->
    <<"The number of events sampled due to sampling enabled.">>;
sampling_metric_description(dropped) ->
    <<"The number of events dropped due to sampling enabled.">>.

sampling_metric_labels(HookName, Criterion) ->
    [{hook, atom_to_list(HookName)}, {acl_name, Criterion}].

sampling_metric_id(HookName, Criterion, Type) ->
    [sampling_metric_name(Type) | sampling_metric_labels(HookName, Criterion)].

%% Read from the same depth counters the dispatcher admits against, so the gauge
%% and the backpressure decision can never disagree. These count events queued
%% *or* in flight -- the one a worker is blocked on is still outstanding work.
%%
%% Emitted as two aggregates rather than one series per worker: max is what
%% saturation alerts fire on, total shows the backlog, and neither grows with pool
%% size. Absent worker names means gRPC is disabled, so no series at all.
%% Connection count and age come from the sampler, which owns the only record of
%% when each connection was first seen -- Erlang exposes no process start time.
grpc_connection_metrics() ->
    case vmq_events_sidecar_grpc_conn_monitor:stats() of
        undefined ->
            [];
        {Connections, MaxAgeSeconds, SampleAgeSeconds} ->
            [
                {gauge, [], grpc_connections_active, grpc_connections_active,
                    <<"The number of live gRPC channel-pool connections.">>, Connections},
                {gauge, [], grpc_connection_age_max_seconds, grpc_connection_age_max_seconds,
                    <<"Age of the oldest live gRPC channel-pool connection, in seconds.">>,
                    MaxAgeSeconds},
                {gauge, [], grpc_connection_sample_age_seconds, grpc_connection_sample_age_seconds,
                    <<
                        "Seconds since the gRPC connection sampler last ran. Should stay below its "
                        "interval; a growing value means the sampler is wedged and the two gauges "
                        "above are frozen."
                    >>,
                    SampleAgeSeconds}
            ]
    end.

grpc_worker_queue_metrics() ->
    case persistent_term:get(?GRPC_WORKER_NAMES, undefined) of
        undefined ->
            [];
        Names ->
            DepthRef = persistent_term:get(?GRPC_DEPTH_COUNTERS),
            {Max, Total} = lists:foldl(
                fun(Slot, {MaxAcc, TotalAcc}) ->
                    %% Clamped: a worker restarting concurrently with a dispatch
                    %% can leave its slot transiently negative.
                    Depth = max(0, atomics:get(DepthRef, Slot)),
                    {max(MaxAcc, Depth), TotalAcc + Depth}
                end,
                {0, 0},
                lists:seq(1, tuple_size(Names))
            ),
            [
                {gauge, [], grpc_worker_queue_max, grpc_worker_queue_max,
                    <<"The deepest gRPC worker queue in the pool (queued or in flight).">>, Max},
                {gauge, [], grpc_worker_queue_total, grpc_worker_queue_total,
                    <<"The total number of events queued or in flight across all gRPC workers.">>,
                    Total}
            ]
    end.

grpc_call_result_metrics() ->
    ets:foldl(
        fun({{HookName, Result}, TotalCount}, Acc) ->
            Labels = [{hook, atom_to_list(HookName)}, {result, atom_to_list(Result)}],
            [
                {counter, Labels, [grpc_call_result | Labels], grpc_call_result,
                    <<"The number of gRPC event-sidecar calls by hook and result.">>, TotalCount}
                | Acc
            ]
        end,
        [],
        ?GRPC_CALL_RESULTS_TABLE
    ).

-spec metrics_defs() -> [metric_def()].
metrics_defs() ->
    Hooks = [
        ?ON_REGISTER,
        ?ON_REGISTER_FAILED,
        ?ON_PUBLISH,
        ?ON_SUBSCRIBE,
        ?ON_UNSUBSCRIBE,
        ?ON_DELIVER,
        ?ON_DELIVERY_COMPLETE,
        ?ON_OFFLINE_MESSAGE,
        ?ON_CLIENT_WAKEUP,
        ?ON_CLIENT_OFFLINE,
        ?ON_CLIENT_GONE,
        ?ON_SESSION_EXPIRED,
        ?ON_MESSAGE_DROP
    ],
    [
        m(
            counter,
            [{hook, atom_to_list(Hook)}],
            {?SIDECAR_EVENTS, Hook},
            sidecar_events,
            <<"The number of events sidecar hook attempts.">>
        )
     || Hook <- Hooks
    ] ++
        [
            m(
                counter,
                [{hook, atom_to_list(Hook)}],
                {?SIDECAR_EVENTS_ERROR, Hook},
                sidecar_events_error,
                <<"The number of times events sidecar hook call failed.">>
            )
         || Hook <- Hooks
        ] ++
        [
            m(
                counter,
                [],
                ?GRPC_WORKER_CRASHED,
                grpc_worker_crashed,
                <<"The number of times a gRPC worker terminated abnormally.">>
            ),
            m(
                counter,
                [],
                ?GRPC_EVENTS_LOST,
                grpc_events_lost,
                <<"The number of events discarded with a gRPC worker that died holding them.">>
            ),
            m(
                counter,
                [],
                ?GRPC_CONNECTS,
                grpc_connects,
                <<"The cumulative number of gRPC channel-pool connections established.">>
            ),
            m(
                counter,
                [],
                ?GRPC_CONNECTIONS_RECYCLED,
                grpc_connections_recycled,
                <<"The number of gRPC connections closed because they reached their max age.">>
            )
        ].

-spec m(atom(), [metric_label()], metric_id(), atom(), binary()) -> metric_def().
m(Type, Labels, UniqueId, Name, Description) ->
    #metric_def{
        type = Type,
        labels = Labels,
        id = UniqueId,
        name = Name,
        description = Description
    }.

met2idx({?SIDECAR_EVENTS, ?ON_REGISTER}) -> 1;
met2idx({?SIDECAR_EVENTS, ?ON_REGISTER_FAILED}) -> 2;
met2idx({?SIDECAR_EVENTS, ?ON_PUBLISH}) -> 3;
met2idx({?SIDECAR_EVENTS, ?ON_SUBSCRIBE}) -> 4;
met2idx({?SIDECAR_EVENTS, ?ON_UNSUBSCRIBE}) -> 5;
met2idx({?SIDECAR_EVENTS, ?ON_DELIVER}) -> 6;
met2idx({?SIDECAR_EVENTS, ?ON_DELIVERY_COMPLETE}) -> 7;
met2idx({?SIDECAR_EVENTS, ?ON_OFFLINE_MESSAGE}) -> 8;
met2idx({?SIDECAR_EVENTS, ?ON_CLIENT_WAKEUP}) -> 9;
met2idx({?SIDECAR_EVENTS, ?ON_CLIENT_OFFLINE}) -> 10;
met2idx({?SIDECAR_EVENTS, ?ON_CLIENT_GONE}) -> 11;
met2idx({?SIDECAR_EVENTS, ?ON_SESSION_EXPIRED}) -> 12;
met2idx({?SIDECAR_EVENTS, ?ON_MESSAGE_DROP}) -> 13;
met2idx({?SIDECAR_EVENTS_ERROR, ?ON_REGISTER}) -> 14;
met2idx({?SIDECAR_EVENTS_ERROR, ?ON_REGISTER_FAILED}) -> 15;
met2idx({?SIDECAR_EVENTS_ERROR, ?ON_PUBLISH}) -> 16;
met2idx({?SIDECAR_EVENTS_ERROR, ?ON_SUBSCRIBE}) -> 17;
met2idx({?SIDECAR_EVENTS_ERROR, ?ON_UNSUBSCRIBE}) -> 18;
met2idx({?SIDECAR_EVENTS_ERROR, ?ON_DELIVER}) -> 19;
met2idx({?SIDECAR_EVENTS_ERROR, ?ON_DELIVERY_COMPLETE}) -> 20;
met2idx({?SIDECAR_EVENTS_ERROR, ?ON_OFFLINE_MESSAGE}) -> 21;
met2idx({?SIDECAR_EVENTS_ERROR, ?ON_CLIENT_WAKEUP}) -> 22;
met2idx({?SIDECAR_EVENTS_ERROR, ?ON_CLIENT_OFFLINE}) -> 23;
met2idx({?SIDECAR_EVENTS_ERROR, ?ON_CLIENT_GONE}) -> 24;
met2idx({?SIDECAR_EVENTS_ERROR, ?ON_SESSION_EXPIRED}) -> 25;
met2idx({?SIDECAR_EVENTS_ERROR, ?ON_MESSAGE_DROP}) -> 26;
met2idx(?GRPC_WORKER_CRASHED) -> 27;
met2idx(?GRPC_EVENTS_LOST) -> 28;
met2idx(?GRPC_CONNECTS) -> 29;
met2idx(?GRPC_CONNECTIONS_RECYCLED) -> 30.
