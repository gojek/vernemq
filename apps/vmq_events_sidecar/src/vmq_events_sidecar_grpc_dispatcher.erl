%% Copyright Gojek

%%%-------------------------------------------------------------------
%% @doc Routes an event to a gRPC worker.
%%
%% Deliberately not a process: this runs inline on the MQTT session process, so
%% there is no extra hop and no single mailbox for every event on the node to
%% squeeze through. All state lives in persistent_term and atomics, making
%% selection a lock-free read.
%%
%% The contract is that dispatch/3 always returns ok and never raises. An MQTT
%% session process must not be able to fail because event forwarding -- which is
%% observability -- had a problem.
%% @end
%%%-------------------------------------------------------------------

-module(vmq_events_sidecar_grpc_dispatcher).
-include("../include/vmq_events_sidecar.hrl").

-export([dispatch/3]).

%% Number of workers tried before an event is dropped. Round-robin already
%% spreads load evenly, so a couple of alternates is enough to absorb one worker
%% stuck behind a slow in-flight call.
-define(MAX_ATTEMPTS, 3).

-spec dispatch(atom(), integer(), any()) -> ok.
dispatch(HookName, Timestamp, EventPayload) ->
    case persistent_term:get(?GRPC_WORKER_NAMES, undefined) of
        undefined ->
            %% Reachable when grpc_percentage is non-zero but grpc_enabled is
            %% off, so the worker supervisor was never started. Counted rather
            %% than crashed.
            drop(HookName, no_workers);
        Names ->
            Ctx = #{
                names => Names,
                depth_ref => persistent_term:get(?GRPC_DEPTH_COUNTERS),
                max_queue_len => persistent_term:get(?GRPC_MAX_QUEUE_LEN)
            },
            Idx = atomics:add_get(persistent_term:get(?GRPC_RR_COUNTER), 1, 1),
            try_dispatch(HookName, Timestamp, EventPayload, Ctx, Idx, ?MAX_ATTEMPTS)
    end.

%%====================================================================
%% Internal functions
%%====================================================================

try_dispatch(HookName, _Timestamp, _EventPayload, _Ctx, _Idx, 0) ->
    drop(HookName, dropped);
try_dispatch(HookName, Timestamp, EventPayload, Ctx, Idx, Attempts) ->
    #{names := Names, depth_ref := DepthRef, max_queue_len := MaxQueueLen} = Ctx,
    Slot = (Idx rem tuple_size(Names)) + 1,
    case whereis(element(Slot, Names)) of
        undefined ->
            %% Worker is mid-restart; the next one is very likely up.
            next(HookName, Timestamp, EventPayload, Ctx, Idx, Attempts);
        Pid ->
            %% Reserve first, send second. add_get is a single atomic op, so two
            %% concurrent dispatchers cannot both claim the last slot.
            case atomics:add_get(DepthRef, Slot, 1) of
                Depth when Depth =< MaxQueueLen ->
                    Pid ! {event, HookName, Timestamp, EventPayload},
                    ok;
                _Full ->
                    atomics:sub(DepthRef, Slot, 1),
                    next(HookName, Timestamp, EventPayload, Ctx, Idx, Attempts)
            end
    end.

next(HookName, Timestamp, EventPayload, Ctx, Idx, Attempts) ->
    try_dispatch(HookName, Timestamp, EventPayload, Ctx, Idx + 1, Attempts - 1).

drop(HookName, Reason) ->
    try
        vmq_events_sidecar_metrics:incr_grpc_call_result(HookName, Reason),
        vmq_events_sidecar_metrics:incr_sidecar_events_error(HookName)
    catch
        Class:Error ->
            lager:warning(
                "could not record dropped ~p event (~p): ~p:~p",
                [HookName, Reason, Class, Error]
            ),
            ok
    end.
