-module(vmq_events_sidecar_SUITE).
-include_lib("vernemq_dev/include/vernemq_dev.hrl").
-include_lib("vmq_commons/include/vmq_types.hrl").
-include("vmq_events_sidecar_test.hrl").
-include("../include/vmq_events_sidecar.hrl").

-export([
         init_per_suite/1,
         end_per_suite/1,
         init_per_testcase/2,
         end_per_testcase/2,
         all/0
        ]).

-compile([export_all]).
-compile([nowarn_export_all]).

-define(TEST_POOL_SIZE, 4).

init_per_suite(Config) ->
    %% Start TCP server for shackle (default) path
    ListenSock = start_tcp_server(),

    %% Start gRPC server for rollout path
    {ok, _} = application:ensure_all_started(grpc),
    events_sidecar_handler:start_grpc_server(),

    application:set_env(vmq_events_sidecar, grpc_enabled, true),
    application:set_env(vmq_events_sidecar, grpc_endpoint, "127.0.0.1"),
    application:set_env(vmq_events_sidecar, grpc_port, 8891),
    application:set_env(vmq_events_sidecar, grpc_pool_size, 5),
    %% Small pool so the dispatch tests can suspend every worker and reason about
    %% exact mailbox depths.
    application:set_env(vmq_events_sidecar, grpc_worker_pool_size, ?TEST_POOL_SIZE),

    application:load(vmq_plugin),
    application:ensure_all_started(vmq_plugin),
    ok = vmq_plugin_mgr:enable_plugin(vmq_events_sidecar),
    ok = vmq_plugin_mgr:enable_plugin(vmq_metrics_plus),
    {ok, _} = vmq_metrics:start_link(),

    {ok, _} = application:ensure_all_started(shackle),
    cover:start(),
    [{socket, ListenSock} |Config].

end_per_suite(Config) ->
    stop_tcp_server(proplists:get_value(socket, Config, [])),
    events_sidecar_handler:stop_grpc_server(),

    ok = vmq_plugin_mgr:disable_plugin(vmq_events_sidecar),
    ok = vmq_plugin_mgr:disable_plugin(vmq_metrics_plus),
    application:stop(vmq_plugin),

    application:stop(shackle),
    application:stop(grpc),
    Config.

init_per_testcase(_Case, Config) ->
    Config.

end_per_testcase(_, Config) ->
    Config.

all() ->
    [on_session_expired_test,
     on_delivery_complete_test,
     on_register_test,
     on_register_empty_properties_test,
     on_register_failed_test,
     on_publish_test,
     on_subscribe_test,
     on_unsubscribe_test,
     on_deliver_test,
     on_offline_message_test,
     on_client_wakeup_test,
     on_client_offline_test,
     on_client_gone_test,
     on_message_drop_test,
     on_register_grpc_test,
     on_publish_grpc_test,
     on_subscribe_grpc_test,
     grpc_worker_pool_started_test,
     grpc_dispatch_round_robin_test,
     grpc_dispatch_retries_next_worker_test,
     grpc_dispatch_drop_when_all_full_test,
     grpc_dispatch_no_workers_test,
     grpc_worker_survives_bad_event_test,
     grpc_worker_queue_metrics_test,
     grpc_worker_crash_restart_test,
     grpc_worker_lost_events_counted_test,
     grpc_connection_metrics_test,
     grpc_connection_recycle_test,
     grpc_connection_recycle_without_traffic_test,
     grpc_connection_recycle_pauses_when_degraded_test,
     grpc_connection_recycle_rate_scales_with_pool_test,
     grpc_connection_recycle_disabled_by_default_test,
     grpc_connection_recycle_enabled_at_runtime_test,
     grpc_disabled_unless_flag_and_endpoint_set_test
    ].


start_tcp_server() ->
  events_sidecar_handler:start_tcp_server().
stop_tcp_server(S) ->
  events_sidecar_handler:stop_tcp_server(S).

%% Test cases (shackle/TCP path — default, percentage=0)
on_register_test(_) ->
    enable_hook(on_register),
    Self = pid_to_bin(self()),
    UserProps = [{"k1", "v1"}, {"k2","v2"}, {"k3","v3"}],
    [ok] = vmq_plugin:all(on_register,
                            [?PEER, {?MOUNTPOINT, ?ALLOWED_CLIENT_ID}, Self, #{?P_USER_PROPERTY => UserProps}, ?SESSION_ID]),
    ok = exp_response(on_register_ok),
    disable_hook(on_register).

on_register_empty_properties_test(_) ->
  enable_hook(on_register),
  Self = pid_to_bin(self()),
  [ok] = vmq_plugin:all(on_register,
    [?PEER, {?MOUNTPOINT, ?ALLOWED_CLIENT_ID}, Self, #{}, ?SESSION_ID]),
  ok = exp_response(on_register_ok),
  disable_hook(on_register).

on_publish_test(_) ->
    enable_hook(on_publish),
    Self = pid_to_bin(self()),
    [ok,ok] = vmq_plugin:all(on_publish,
                           [Self, {?MOUNTPOINT, ?ALLOWED_CLIENT_ID}, 1, ?TOPIC, ?PAYLOAD, false, #matched_acl{name = ?LABEL, pattern = ?PATTERN}, ?SESSION_ID]),
    ok = exp_response(on_publish_ok),
    disable_hook(on_publish).

on_subscribe_test(_) ->
    enable_hook(on_subscribe),
    Self = pid_to_bin(self()),
    [ok,ok] = vmq_plugin:all(on_subscribe,
                            [Self, {?MOUNTPOINT, ?ALLOWED_CLIENT_ID}, [{?TOPIC, 1, #matched_acl{name = ?LABEL, pattern = ?PATTERN}},
                                                                       {?TOPIC, not_allowed, #matched_acl{}}], ?SESSION_ID]),
    ok = exp_response(on_subscribe_ok),
    disable_hook(on_subscribe).

on_unsubscribe_test(_) ->
    enable_hook(on_unsubscribe),
    Self = pid_to_bin(self()),
    ok = vmq_plugin:all_till_ok(on_unsubscribe,
                                [Self, {?MOUNTPOINT, ?ALLOWED_CLIENT_ID}, [?TOPIC], ?SESSION_ID]),
    ok = exp_response(on_unsubscribe_ok),
    disable_hook(on_unsubscribe).

on_deliver_test(_) ->
    enable_hook(on_deliver),
    Self = pid_to_bin(self()),
    ok = vmq_plugin:all_till_ok(on_deliver,
                                [Self, {?MOUNTPOINT, ?ALLOWED_CLIENT_ID}, 1, ?TOPIC, ?PAYLOAD, false, #matched_acl{name = ?LABEL, pattern = ?PATTERN}, true, ?SESSION_ID]),
    ok = exp_response(on_deliver_ok),
    disable_hook(on_deliver).

on_delivery_complete_test(_) ->
  enable_hook(on_delivery_complete),
  Self = pid_to_bin(self()),
  [ok,ok] = vmq_plugin:all(on_delivery_complete,[Self, {?MOUNTPOINT, ?ALLOWED_CLIENT_ID}, 1, ?TOPIC, ?PAYLOAD, false, #matched_acl{name = ?LABEL, pattern = ?PATTERN}, true, ?SESSION_ID]),
  ok = exp_response(on_delivery_complete_ok),
  disable_hook(on_delivery_complete).

on_offline_message_test(_) ->
    enable_hook(on_offline_message),
    Self = pid_to_bin(self()),
    [ok] = vmq_plugin:all(on_offline_message, [{?MOUNTPOINT, Self}, 1, ?TOPIC, ?PAYLOAD, false, ?SESSION_ID]),
    ok = exp_response(on_offline_message_ok),
    disable_hook(on_offline_message).

on_client_wakeup_test(_) ->
    enable_hook(on_client_wakeup),
    Self = pid_to_bin(self()),
    [ok] = vmq_plugin:all(on_client_wakeup, [{?MOUNTPOINT, Self}, ?SESSION_ID]),
    ok = exp_response(on_client_wakeup_ok),
    disable_hook(on_client_wakeup).

on_client_offline_test(_) ->
    enable_hook(on_client_offline),
    Self = pid_to_bin(self()),
    [ok] = vmq_plugin:all(on_client_offline, [{?MOUNTPOINT, ?ALLOWED_CLIENT_ID}, ?REASON, Self, ?SESSION_ID]),
    ok = exp_response(on_client_offline_ok),
    disable_hook(on_client_offline).

on_client_gone_test(_) ->
    enable_hook(on_client_gone),
    Self = pid_to_bin(self()),
    [ok] = vmq_plugin:all(on_client_gone, [{?MOUNTPOINT, ?ALLOWED_CLIENT_ID}, ?REASON, Self, ?SESSION_ID]),
    ok = exp_response(on_client_gone_ok),
    disable_hook(on_client_gone).

on_session_expired_test(_) ->
    enable_hook(on_session_expired),
    Self = pid_to_bin(self()),
    [ok] = vmq_plugin:all(on_session_expired, [{?MOUNTPOINT, Self}, ?SESSION_ID]),
    ok = exp_response(on_session_expired_ok),
    disable_hook(on_session_expired).

on_message_drop_test(_) ->
    enable_hook(on_message_drop),
    Self = pid_to_bin(self()),
    [ok,ok] = vmq_plugin:all(on_message_drop, [{?MOUNTPOINT, Self}, fun() -> {?TOPIC, 1, ?PAYLOAD, #{}, #matched_acl{name = ?LABEL, pattern = ?PATTERN}} end, binary_to_atom(?MESSAGE_DROP_REASON), ?SESSION_ID]),
    ok = exp_response(on_message_drop_ok),
    disable_hook(on_message_drop).

on_register_failed_test(_) ->
    enable_hook(on_register_failed),
    Self = pid_to_bin(self()),
    [ok] = vmq_plugin:all(on_register_failed,
                          [?PEER, {?MOUNTPOINT, ?ALLOWED_CLIENT_ID}, Self, true, invalid_credentials]),
    ok = exp_response(on_register_failed_ok),
    disable_hook(on_register_failed).

%% Test gRPC path (percentage=100)
on_register_grpc_test(_) ->
    vmq_events_sidecar_plugin:set_grpc_percentage(100),
    enable_hook(on_register),
    Self = pid_to_bin(self()),
    UserProps = [{"k1", "v1"}, {"k2","v2"}, {"k3","v3"}],
    [ok] = vmq_plugin:all(on_register,
                            [?PEER, {?MOUNTPOINT, ?ALLOWED_CLIENT_ID}, Self, #{?P_USER_PROPERTY => UserProps}, ?SESSION_ID]),
    ok = exp_response(on_register_ok),
    disable_hook(on_register),
    vmq_events_sidecar_plugin:set_grpc_percentage(0).

on_publish_grpc_test(_) ->
    vmq_events_sidecar_plugin:set_grpc_percentage(100),
    enable_hook(on_publish),
    Self = pid_to_bin(self()),
    [ok,ok] = vmq_plugin:all(on_publish,
                           [Self, {?MOUNTPOINT, ?ALLOWED_CLIENT_ID}, 1, ?TOPIC, ?PAYLOAD, false, #matched_acl{name = ?LABEL, pattern = ?PATTERN}, ?SESSION_ID]),
    ok = exp_response(on_publish_ok),
    disable_hook(on_publish),
    vmq_events_sidecar_plugin:set_grpc_percentage(0).

on_subscribe_grpc_test(_) ->
    vmq_events_sidecar_plugin:set_grpc_percentage(100),
    enable_hook(on_subscribe),
    Self = pid_to_bin(self()),
    [ok,ok] = vmq_plugin:all(on_subscribe,
                            [Self, {?MOUNTPOINT, ?ALLOWED_CLIENT_ID}, [{?TOPIC, 1, #matched_acl{name = ?LABEL, pattern = ?PATTERN}},
                                                                       {?TOPIC, not_allowed, #matched_acl{}}], ?SESSION_ID]),
    ok = exp_response(on_subscribe_ok),
    disable_hook(on_subscribe),
    vmq_events_sidecar_plugin:set_grpc_percentage(0).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% gRPC worker pool
%%
%% These drive vmq_events_sidecar_grpc_dispatcher:dispatch/3 directly rather than
%% through the hooks, so they do not depend on the rollout percentage. Workers are
%% suspended so mailbox depths stay put long enough to assert on.
%%
%% The probe payload is deliberately unencodable ({} does not match any
%% vmq_events_sidecar_format:encode/1 clause), so an event that reaches a worker
%% is counted as encode_error and never touches the network. The hook name is a
%% real one because vmq_events_sidecar_metrics:met2idx/1 has no catch-all.
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
grpc_worker_pool_started_test(_) ->
    %% grpc_enabled is on for this suite, so the conditional child must be there.
    Children = [Id || {Id, _Pid, _Type, _Mods} <- supervisor:which_children(
        vmq_events_sidecar_sup
    )],
    true = lists:member(vmq_events_sidecar_grpc_worker_sup, Children),
    Names = persistent_term:get(?GRPC_WORKER_NAMES),
    ?TEST_POOL_SIZE = tuple_size(Names),
    [] = [N || N <- tuple_to_list(Names), whereis(N) =:= undefined],
    2000 = persistent_term:get(?GRPC_MAX_QUEUE_LEN),
    %% add 0 reads the counter without disturbing round-robin ordering
    Counter = persistent_term:get(?GRPC_RR_COUNTER),
    true = is_integer(atomics:add_get(Counter, 1, 0)),
    %% One depth slot per worker, and the array must be signed -- an unsigned
    %% array would wrap a transient negative into a huge value and wedge the
    %% worker as permanently full.
    DepthRef = persistent_term:get(?GRPC_DEPTH_COUNTERS),
    #{size := ?TEST_POOL_SIZE, min := Min} = atomics:info(DepthRef),
    true = Min < 0,
    ok.

grpc_dispatch_round_robin_test(_) ->
    Pids = worker_pids(),
    ok = drain_workers(),
    suspend_all(Pids),
    try
        [dispatch_probe() || _ <- Pids],
        %% One event per worker, dispatched pool-size times: every worker must
        %% have exactly one. Anything else means selection is not round-robin.
        Lens = [queue_len(P) || P <- Pids],
        Expected = [1 || _ <- Pids],
        Expected = Lens
    after
        resume_all(Pids)
    end,
    ok = drain_workers().

grpc_dispatch_retries_next_worker_test(_) ->
    Pids = worker_pids(),
    ok = drain_workers(),
    Saved = persistent_term:get(?GRPC_MAX_QUEUE_LEN),
    persistent_term:put(?GRPC_MAX_QUEUE_LEN, 1),
    Before = metric_value(grpc_call_result, [{hook, "on_publish"}, {result, "dropped"}]),
    suspend_all(Pids),
    try
        %% Fill worker 1 to its threshold, then aim the next dispatch at it again.
        %% A pool that drops on first refusal leaves worker 2 empty.
        aim_at_worker(1),
        ok = dispatch_probe(),
        1 = depth(1),
        aim_at_worker(1),
        ok = dispatch_probe(),
        1 = depth(1),
        1 = depth(2),
        Before = metric_value(grpc_call_result, [{hook, "on_publish"}, {result, "dropped"}])
    after
        resume_all(Pids),
        persistent_term:put(?GRPC_MAX_QUEUE_LEN, Saved)
    end,
    ok = drain_workers().

grpc_dispatch_drop_when_all_full_test(_) ->
    Pids = worker_pids(),
    ok = drain_workers(),
    Saved = persistent_term:get(?GRPC_MAX_QUEUE_LEN),
    persistent_term:put(?GRPC_MAX_QUEUE_LEN, 1),
    DroppedBefore = metric_value(grpc_call_result, [{hook, "on_publish"}, {result, "dropped"}]),
    ErrorsBefore = metric_value(sidecar_events_error, [{hook, "on_publish"}]),
    suspend_all(Pids),
    try
        %% Round-robin means pool-size dispatches fill every worker to 1.
        [ok = dispatch_probe() || _ <- Pids],
        [] = [S || S <- slots(), depth(S) =/= 1],
        %% Nowhere left to put it. dispatch/3 must still return ok: a saturated
        %% pool may never surface as an error on the MQTT session process.
        ok = dispatch_probe(),
        DroppedAfter = metric_value(grpc_call_result, [{hook, "on_publish"}, {result, "dropped"}]),
        DroppedAfter = DroppedBefore + 1,
        ErrorsAfter = metric_value(sidecar_events_error, [{hook, "on_publish"}]),
        ErrorsAfter = ErrorsBefore + 1,
        %% A refused reservation must be rolled back, not left inflating depth.
        [] = [S || S <- slots(), depth(S) =/= 1]
    after
        resume_all(Pids),
        persistent_term:put(?GRPC_MAX_QUEUE_LEN, Saved)
    end,
    ok = drain_workers().

grpc_dispatch_no_workers_test(_) ->
    ok = drain_workers(),
    Names = persistent_term:get(?GRPC_WORKER_NAMES),
    Before = metric_value(grpc_call_result, [{hook, "on_publish"}, {result, "no_workers"}]),
    persistent_term:erase(?GRPC_WORKER_NAMES),
    try
        %% Reachable when grpc_percentage is non-zero but grpc_enabled is off.
        %% Must be counted, not raised into the caller.
        ok = dispatch_probe(),
        After = metric_value(grpc_call_result, [{hook, "on_publish"}, {result, "no_workers"}]),
        After = Before + 1,
        %% Same state a broker with gRPC disabled is in: it must not publish
        %% queue-depth series for a pool that does not exist.
        undefined = metric_type(grpc_worker_queue_max),
        undefined = metric_type(grpc_worker_queue_total)
    after
        persistent_term:put(?GRPC_WORKER_NAMES, Names)
    end,
    ok.

grpc_worker_survives_bad_event_test(_) ->
    ok = drain_workers(),
    [Pid | _] = worker_pids(),
    Before = metric_value(grpc_call_result, [{hook, "on_publish"}, {result, "encode_error"}]),
    aim_at_worker(1),
    ok = dispatch_probe(),
    ok = wait_until(fun() ->
        metric_value(grpc_call_result, [{hook, "on_publish"}, {result, "encode_error"}]) > Before
    end),
    %% Same pid: an event it cannot encode must not cost the worker its mailbox.
    [Pid | _] = worker_pids(),
    true = is_process_alive(Pid),
    %% and the reservation was released even though the event failed
    ok = wait_until(fun() -> depth(1) =:= 0 end),
    ok.

grpc_worker_queue_metrics_test(_) ->
    Pids = worker_pids(),
    ok = drain_workers(),
    0 = metric_value(grpc_worker_queue_total, []),
    suspend_all(Pids),
    try
        aim_at_worker(1),
        ok = dispatch_probe(),
        aim_at_worker(1),
        ok = dispatch_probe(),
        aim_at_worker(2),
        ok = dispatch_probe(),
        2 = metric_value(grpc_worker_queue_max, []),
        3 = metric_value(grpc_worker_queue_total, []),
        gauge = metric_type(grpc_worker_queue_max),
        gauge = metric_type(grpc_worker_queue_total)
    after
        resume_all(Pids)
    end,
    ok = drain_workers().

%% The reason the depth counters exist. A worker killed outright skips terminate/2
%% entirely, so grpc_worker_crashed cannot fire and the mailbox is gone -- but the
%% reservations it never released are still in its slot, and the replacement worker
%% reports them.
grpc_worker_lost_events_counted_test(_) ->
    Pids = worker_pids(),
    ok = drain_workers(),
    Name = vmq_events_sidecar_grpc_worker:name(1),
    Pid = whereis(Name),
    LostBefore = metric_value(grpc_events_lost, []),
    suspend_all(Pids),
    try
        [begin aim_at_worker(1), ok = dispatch_probe() end || _ <- lists:seq(1, 3)],
        3 = depth(1),
        %% Killed while still suspended, and with kill so terminate/2 never runs.
        %% Resuming first would let the worker drain the queue and release the very
        %% reservations this test is about.
        exit(Pid, kill),
        ok = wait_until(fun() ->
            case whereis(Name) of
                undefined -> false;
                New -> New =/= Pid
            end
        end),
        ok = wait_until(fun() -> metric_value(grpc_events_lost, []) =:= LostBefore + 3 end),
        %% Slot handed back clean, so the replacement starts with full capacity.
        ok = wait_until(fun() -> depth(1) =:= 0 end)
    after
        %% Only the ones this process actually suspended; the replacement worker
        %% was never suspended and resume_process/1 would raise badarg on it.
        resume_all(Pids -- [Pid])
    end,
    ok = drain_workers().

grpc_worker_crash_restart_test(_) ->
    ok = drain_workers(),
    Name = vmq_events_sidecar_grpc_worker:name(1),
    Pid = whereis(Name),
    Before = metric_value(grpc_worker_crashed, []),
    %% sys:terminate drives terminate/2 with an abnormal reason, which exit/2
    %% with kill would skip.
    sys:terminate(Pid, kaboom),
    ok = wait_until(fun() ->
        case whereis(Name) of
            undefined -> false;
            New -> New =/= Pid
        end
    end),
    After = metric_value(grpc_worker_crashed, []),
    After = Before + 1,
    %% Restarted in place, and the rest of the pool was untouched.
    ?TEST_POOL_SIZE = length(worker_pids()),
    ok.

%% The channel pool is grpc_pool_size (5 here) gun connections, and gun is the
%% only user of gun_conns_sup in the release, so the sampler should see exactly
%% those.
grpc_connection_metrics_test(_) ->
    ok = vmq_events_sidecar_grpc_conn_monitor:sample_now(),
    GunConns = length(supervisor:which_children(gun_conns_sup)),
    Active = metric_value(grpc_connections_active, []),
    Active = GunConns,
    true = Active > 0,
    gauge = metric_type(grpc_connections_active),
    gauge = metric_type(grpc_connection_age_max_seconds),
    gauge = metric_type(grpc_connection_sample_age_seconds),
    %% Every live connection was counted on the way in, so the cumulative
    %% counter can never be below the live count.
    true = metric_value(grpc_connects, []) >= Active,
    %% Age is measured from first sight, so it is defined but may still be 0.
    true = metric_value(grpc_connection_age_max_seconds, []) >= 0,
    %% Re-sampling an unchanged pool must not inflate the counter.
    Before = metric_value(grpc_connects, []),
    ok = vmq_events_sidecar_grpc_conn_monitor:sample_now(),
    Before = metric_value(grpc_connects, []),
    ok.

%% Closing a connection makes grpc_client re-dial, which re-resolves the
%% endpoint. That is the whole point of recycling.
grpc_connection_recycle_test(_) ->
    ok = vmq_events_sidecar_grpc_conn_monitor:sample_now(),
    Before = conn_pids(),
    RecycledBefore = metric_value(grpc_connections_recycled, []),

    {ok, Closed} = vmq_events_sidecar_grpc_conn_monitor:recycle_oldest_now(),
    true = lists:member(Closed, Before),

    %% Counted, and actually gone.
    RecycledAfter = metric_value(grpc_connections_recycled, []),
    RecycledAfter = RecycledBefore + 1,
    ok = wait_until(fun() -> not is_process_alive(Closed) end),
    ok = wait_until(fun() -> not lists:member(Closed, conn_pids()) end),

    %% The published count is a snapshot taken at the start of a tick, so it
    %% cannot be compared to a fresh live read -- the async reconnect may land in
    %% between. Bound it instead: never zero, never above the pool.
    ok = vmq_events_sidecar_grpc_conn_monitor:sample_now(),
    {Active, _MaxAge, _SampleAge} = vmq_events_sidecar_grpc_conn_monitor:stats(),
    true = Active > 0 andalso Active =< length(Before),

    %% recycle/1 triggers the reconnect itself, so the pool heals with no traffic
    %% and no manual poking.
    ok = wait_until(fun() -> length(conn_pids()) =:= length(Before) end),

    %% Recycling must not permanently shrink the pool.
    ok = vmq_events_sidecar_grpc_conn_monitor:sample_now(),
    {Restored, _MaxAge2, _SampleAge2} = vmq_events_sidecar_grpc_conn_monitor:stats(),
    Restored = length(Before),
    ok.

%% Regression: recycling must not depend on traffic to reconnect, or an idle pool
%% is closed connection by connection and stays down.
grpc_connection_recycle_without_traffic_test(_) ->
    0 = vmq_events_sidecar_plugin:get_grpc_percentage(),
    ok = vmq_events_sidecar_grpc_conn_monitor:sample_now(),
    Expected = length(conn_pids()),
    true = Expected > 0,
    %% Recycle every connection in the pool with no traffic whatsoever.
    lists:foreach(
        fun(_) ->
            {ok, _Closed} = vmq_events_sidecar_grpc_conn_monitor:recycle_oldest_now(),
            ok = wait_until(fun() -> length(conn_pids()) =:= Expected end)
        end,
        lists:seq(1, Expected)
    ),
    %% Pool intact, and the monitor agrees.
    ok = vmq_events_sidecar_grpc_conn_monitor:sample_now(),
    {Expected, _MaxAge, _SampleAge} = vmq_events_sidecar_grpc_conn_monitor:stats(),
    ok.

%% A pool that is already short must not be recycled further.
grpc_connection_recycle_pauses_when_degraded_test(_) ->
    ok = vmq_events_sidecar_grpc_conn_monitor:sample_now(),
    Expected = length(conn_pids()),
    Saved = application:get_env(vmq_events_sidecar, grpc_pool_size, 5),
    %% Claim the pool should be bigger than it is, so it always looks degraded.
    application:set_env(vmq_events_sidecar, grpc_pool_size, Expected + 1),
    RecycledBefore = metric_value(grpc_connections_recycled, []),
    try
        %% Age everything out, then tick: no recycling may happen.
        application:set_env(vmq_events_sidecar, grpc_connection_max_age_seconds, 1),
        timer:sleep(1100),
        ok = vmq_events_sidecar_grpc_conn_monitor:sample_now(),
        ok = vmq_events_sidecar_grpc_conn_monitor:sample_now(),
        RecycledBefore = metric_value(grpc_connections_recycled, []),
        Expected = length(conn_pids())
    after
        application:set_env(vmq_events_sidecar, grpc_pool_size, Saved),
        application:set_env(vmq_events_sidecar, grpc_connection_max_age_seconds, 0)
    end,
    ok.

%% The per-tick budget must scale with pool size and max age: with everything
%% due, more than one connection must be recycled in a single tick.
grpc_connection_recycle_rate_scales_with_pool_test(_) ->
    ok = vmq_events_sidecar_grpc_conn_monitor:sample_now(),
    Expected = length(conn_pids()),
    true = Expected > 1,
    Before = metric_value(grpc_connections_recycled, []),
    application:set_env(vmq_events_sidecar, grpc_connection_max_age_seconds, 1),
    try
        %% Everything is now older than its deadline.
        timer:sleep(1100),
        ok = vmq_events_sidecar_grpc_conn_monitor:sample_now(),
        Recycled = metric_value(grpc_connections_recycled, []) - Before,
        true = Recycled > 1
    after
        application:set_env(vmq_events_sidecar, grpc_connection_max_age_seconds, 0)
    end,
    %% And the pool comes back on its own.
    ok = wait_until(fun() -> length(conn_pids()) =:= Expected end),
    ok.

%% Recycling is opt-in, since closing a connection fails whatever was in flight
%% on it.
grpc_connection_recycle_disabled_by_default_test(_) ->
    Saved = application:get_env(vmq_events_sidecar, grpc_connection_max_age_seconds),
    application:unset_env(vmq_events_sidecar, grpc_connection_max_age_seconds),
    Before = metric_value(grpc_connections_recycled, []),
    try
        ok = vmq_events_sidecar_grpc_conn_monitor:sample_now(),
        ok = vmq_events_sidecar_grpc_conn_monitor:sample_now(),
        Before = metric_value(grpc_connections_recycled, [])
    after
        case Saved of
            {ok, V} -> application:set_env(vmq_events_sidecar, grpc_connection_max_age_seconds, V);
            undefined -> ok
        end
    end,
    ok.

%% Deadlines are stamped when a connection is first seen, so enabling recycling on
%% a running node has to rewrite them or it would never take effect.
grpc_connection_recycle_enabled_at_runtime_test(_) ->
    application:set_env(vmq_events_sidecar, grpc_connection_max_age_seconds, 0),
    ok = vmq_events_sidecar_grpc_conn_monitor:sample_now(),
    Expected = length(conn_pids()),
    Before = metric_value(grpc_connections_recycled, []),
    %% Connections tracked while disabled carry no deadline. Enabling must give
    %% them one without waiting for the pool to churn.
    application:set_env(vmq_events_sidecar, grpc_connection_max_age_seconds, 1),
    try
        ok = vmq_events_sidecar_grpc_conn_monitor:sample_now(),
        timer:sleep(1100),
        ok = vmq_events_sidecar_grpc_conn_monitor:sample_now(),
        true = metric_value(grpc_connections_recycled, []) > Before
    after
        application:set_env(vmq_events_sidecar, grpc_connection_max_age_seconds, 0)
    end,
    ok = wait_until(fun() -> length(conn_pids()) =:= Expected end),
    ok.

%% The flag is what gates every gRPC process at boot, so both halves of it have
%% to hold: off means off even with an endpoint, and on with no endpoint must not
%% count as enabled.
grpc_disabled_unless_flag_and_endpoint_set_test(_) ->
    true = vmq_events_sidecar_grpc_client:enabled(),
    try
        application:set_env(vmq_events_sidecar, grpc_enabled, false),
        false = vmq_events_sidecar_grpc_client:enabled(),
        application:set_env(vmq_events_sidecar, grpc_enabled, true),
        application:set_env(vmq_events_sidecar, grpc_endpoint, ""),
        false = vmq_events_sidecar_grpc_client:enabled(),
        application:unset_env(vmq_events_sidecar, grpc_enabled),
        false = vmq_events_sidecar_grpc_client:enabled()
    after
        application:set_env(vmq_events_sidecar, grpc_enabled, true),
        application:set_env(vmq_events_sidecar, grpc_endpoint, "127.0.0.1")
    end,
    true = vmq_events_sidecar_grpc_client:enabled(),
    ok.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% helper functions
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
enable_hook(Hook) ->
    ok = clique:run(["vmq-admin", "events", "enable", "hook=" ++ atom_to_list(Hook)]).

disable_hook(Hook) ->
    ok = clique:run(["vmq-admin", "events", "disable", "hook=" ++ atom_to_list(Hook)]),
    _ = vmq_events_sidecar_plugin:all_hooks().

pid_to_bin(Pid) ->
    list_to_binary(lists:flatten(io_lib:format("~p", [Pid]))).

exp_response(Exp) ->
    receive
        Exp -> ok;
        Got -> {received, Got, expected, Exp}
    after
        5000 ->
            {didnt_receive_response, Exp}
    end.

exp_nothing(Timeout) ->
    receive
        Got ->
            {received, Got, expected, nothing}
    after
        Timeout ->
            ok
    end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% gRPC worker pool helpers
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
conn_pids() ->
    [Pid || {_Id, Pid, _Type, _Mods} <- supervisor:which_children(gun_conns_sup), is_pid(Pid)].

worker_names() ->
    tuple_to_list(persistent_term:get(?GRPC_WORKER_NAMES)).

worker_pids() ->
    [whereis(N) || N <- worker_names()].

%% {} matches no encode/1 clause, so this never reaches the network.
probe_event() ->
    {event, on_publish, os:system_time(), {}}.

dispatch_probe() ->
    vmq_events_sidecar_grpc_dispatcher:dispatch(on_publish, os:system_time(), {}).

%% Point the round-robin counter so the next dispatch selects worker N (1-based).
%% dispatch/3 does add_get(+1) and then element((Idx rem Size) + 1, Names).
aim_at_worker(N) ->
    Counter = persistent_term:get(?GRPC_RR_COUNTER),
    atomics:put(Counter, 1, N - 2 + ?TEST_POOL_SIZE),
    ok.

slots() ->
    lists:seq(1, ?TEST_POOL_SIZE).

%% Events reserved against a worker but not yet released: what the dispatcher
%% admits against and what the queue gauges report.
depth(Slot) ->
    atomics:get(persistent_term:get(?GRPC_DEPTH_COUNTERS), Slot).

queue_len(Pid) ->
    case erlang:process_info(Pid, message_queue_len) of
        {message_queue_len, Len} -> Len;
        undefined -> undefined
    end.

suspend_all(Pids) ->
    [erlang:suspend_process(P) || P <- Pids],
    ok.

resume_all(Pids) ->
    [erlang:resume_process(P) || P <- Pids, is_process_alive(P)],
    ok.

%% Workers drop probe events on the floor (encode_error), so zero depth and empty
%% mailboxes across the pool mean the previous test left nothing behind.
drain_workers() ->
    wait_until(fun() ->
        lists:all(fun(Slot) -> depth(Slot) =:= 0 end, slots()) andalso
            lists:all(fun(Pid) -> queue_len(Pid) =:= 0 end, worker_pids())
    end).

wait_until(Fun) ->
    wait_until(Fun, 100).

wait_until(_Fun, 0) ->
    timeout;
wait_until(Fun, Retries) ->
    case Fun() of
        true ->
            ok;
        _ ->
            timer:sleep(50),
            wait_until(Fun, Retries - 1)
    end.

metric_value(Name, Labels) ->
    case
        [
            V
         || {_Type, L, _Id, N, _Desc, V} <- vmq_events_sidecar_metrics:metrics(),
            N =:= Name,
            L =:= Labels
        ]
    of
        [V] -> V;
        [] -> 0
    end.

metric_type(Name) ->
    case
        [
            Type
         || {Type, _L, _Id, N, _Desc, _V} <- vmq_events_sidecar_metrics:metrics(),
            N =:= Name
        ]
    of
        [Type] -> Type;
        [] -> undefined
    end.
