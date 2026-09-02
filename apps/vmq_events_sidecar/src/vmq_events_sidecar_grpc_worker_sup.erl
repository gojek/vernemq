%% Copyright Gojek

%%%-------------------------------------------------------------------
%% @doc Supervisor for the fixed gRPC event forwarding worker pool.
%%
%% Started as a child of vmq_events_sidecar_sup, but only when grpc_enabled is
%% on -- a broker that has not opted into gRPC runs exactly the processes it ran
%% before this pool existed.
%% @end
%%%-------------------------------------------------------------------

-module(vmq_events_sidecar_grpc_worker_sup).
-include("../include/vmq_events_sidecar.hrl").

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).
-define(DEFAULT_POOL_SIZE, 100).
-define(DEFAULT_MAX_QUEUE_LEN, 2000).

%%====================================================================
%% API functions
%%====================================================================

-spec start_link() -> 'ignore' | {'error', any()} | {'ok', pid()}.
start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

%%====================================================================
%% Supervisor callbacks
%%====================================================================

init([]) ->
    PoolSize = max(1, application:get_env(?APP, grpc_worker_pool_size, ?DEFAULT_POOL_SIZE)),
    MaxQueueLen = max(
        1, application:get_env(?APP, grpc_worker_max_queue_len, ?DEFAULT_MAX_QUEUE_LEN)
    ),

    Names = list_to_tuple([vmq_events_sidecar_grpc_worker:name(N) || N <- lists:seq(1, PoolSize)]),
    persistent_term:put(?GRPC_WORKER_NAMES, Names),
    persistent_term:put(?GRPC_MAX_QUEUE_LEN, MaxQueueLen),

    %% Unsigned, so the round-robin ticket wraps to 0 rather than to a negative
    %% value: (Idx rem PoolSize) + 1 must stay a valid tuple index.
    maybe_new_atomics(?GRPC_RR_COUNTER, 1, [{signed, false}]),
    %% Signed, because a worker that dies mid-event leaves its slot transiently
    %% negative until reconcile_lost_events/2 settles it.
    maybe_new_atomics(?GRPC_DEPTH_COUNTERS, PoolSize, [{signed, true}]),

    SupFlags = #{strategy => one_for_one, intensity => PoolSize, period => 10},

    ChildSpecs = [
        #{
            id => vmq_events_sidecar_grpc_worker:name(N),
            start => {vmq_events_sidecar_grpc_worker, start_link, [N]},
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [vmq_events_sidecar_grpc_worker]
        }
     || N <- lists:seq(1, PoolSize)
    ],

    {ok, {SupFlags, ChildSpecs}}.

%%====================================================================
%% Internal functions
%%====================================================================

maybe_new_atomics(Key, Arity, Opts) ->
    case persistent_term:get(Key, undefined) of
        undefined ->
            persistent_term:put(Key, atomics:new(Arity, Opts));
        _ExistingRef ->
            ok
    end.
