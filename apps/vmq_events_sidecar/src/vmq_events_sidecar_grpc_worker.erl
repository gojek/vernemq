%% Copyright Gojek

%%%-------------------------------------------------------------------
%% @doc gRPC event forwarding worker.
%%
%% One of a fixed pool of long-lived workers owned by
%% vmq_events_sidecar_grpc_worker_sup. Events arrive as plain messages from
%% vmq_events_sidecar_grpc_dispatcher, which runs on the MQTT session process;
%% the worker owns everything expensive from there on, so the session process
%% never blocks on encoding or on the network.
%%
%% The gRPC call is synchronous, so a worker handles one event at a time for the
%% full round-trip. Pool concurrency comes from worker count, not pipelining --
%% see grpc_worker_pool_size.
%% @end
%%%-------------------------------------------------------------------

-module(vmq_events_sidecar_grpc_worker).
-include("../include/vmq_events_sidecar.hrl").

-behaviour(gen_server).

%% API
-export([
    start_link/1,
    name/1
]).

%% gen_server callbacks
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-record(state, {
    name :: atom(),
    slot :: pos_integer(),
    depth_ref :: atomics:atomics_ref()
}).

%%====================================================================
%% API
%%====================================================================

%% @doc Registered name of the Nth worker. The supervisor and the dispatcher
%% both derive names from here so there is a single definition.
-spec name(pos_integer()) -> atom().
name(N) when is_integer(N), N > 0 ->
    list_to_atom("vmq_events_sidecar_grpc_worker_" ++ integer_to_list(N)).

-spec start_link(pos_integer()) -> {ok, pid()} | ignore | {error, any()}.
start_link(N) ->
    Name = name(N),
    gen_server:start_link({local, Name}, ?MODULE, [Name, N], []).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([Name, Slot]) ->
    DepthRef = persistent_term:get(?GRPC_DEPTH_COUNTERS),
    reconcile_lost_events(DepthRef, Slot),
    {ok, #state{name = Name, slot = Slot, depth_ref = DepthRef}}.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(
    {event, HookName, Timestamp, EventPayload},
    #state{slot = Slot, depth_ref = DepthRef} = State
) ->
    try
        handle_event(HookName, Timestamp, EventPayload)
    catch
        Class:Reason:Stacktrace ->
            lager:warning(
                "gRPC event send failed for ~p: ~p:~p ~p",
                [HookName, Class, Reason, Stacktrace]
            ),
            vmq_events_sidecar_metrics:incr_grpc_call_result(HookName, crashed),
            vmq_events_sidecar_metrics:incr_sidecar_events_error(HookName)
    after
        atomics:sub(DepthRef, Slot, 1)
    end,
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(normal, _State) ->
    ok;
terminate(shutdown, _State) ->
    ok;
terminate({shutdown, _}, _State) ->
    ok;
terminate(_Reason, _State) ->
    vmq_events_sidecar_metrics:incr_grpc_worker_crashed(),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%====================================================================
%% Internal functions
%%====================================================================

%% A slot left non-zero by the previous occupant of this position counts events
%% that were queued or in flight when it died: nothing else decrements the slot,
%% and Erlang gives no way to recover a dead process's mailbox. This is the only
%% place the *size* of that loss is observable.
reconcile_lost_events(DepthRef, Slot) ->
    case atomics:get(DepthRef, Slot) of
        Lost when Lost > 0 ->
            atomics:sub(DepthRef, Slot, Lost),
            vmq_events_sidecar_metrics:incr_grpc_events_lost(Lost),
            lager:warning(
                "gRPC worker ~p restarted with ~p event(s) outstanding; they are lost",
                [Slot, Lost]
            );
        _NothingOutstanding ->
            ok
    end.

handle_event(HookName, Timestamp, EventPayload) ->
    case vmq_events_sidecar_format:encode({HookName, Timestamp, EventPayload}) of
        <<>> ->
            vmq_events_sidecar_metrics:incr_grpc_call_result(HookName, encode_error),
            vmq_events_sidecar_metrics:incr_sidecar_events_error(HookName);
        AnyRecord ->
            case vmq_events_sidecar_grpc_client:send_event(HookName, AnyRecord) of
                ok ->
                    ok;
                {error, _Reason} ->
                    vmq_events_sidecar_metrics:incr_sidecar_events_error(HookName)
            end
    end.
