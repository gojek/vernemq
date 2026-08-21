%%%-------------------------------------------------------------------
%% @doc vmq_events_sidecar top level supervisor.
%% @end
%%%-------------------------------------------------------------------

-module(vmq_events_sidecar_sup).
-include("../include/vmq_events_sidecar.hrl").

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).

%%====================================================================
%% API functions
%%====================================================================
-spec start_link() -> 'ignore' | {'error', any()} | {'ok', pid()}.
start_link() ->
    case supervisor:start_link({local, ?SERVER}, ?MODULE, []) of
        {ok, _} = Ret ->
            spawn(fun() ->
                Hooks = application:get_env(vmq_events_sidecar, hooks, "[]"),
                HooksList = vmq_schema_util:parse_list(Hooks),
                lists:foreach(
                    fun(Hook) -> vmq_events_sidecar_plugin:enable_event(Hook) end, HooksList
                ),

                Sampler = application:get_env(
                    vmq_events_sidecar, sampler, []
                ),
                SamplingHooks = [
                    on_publish,
                    on_deliver,
                    on_delivery_complete
                ],
                lists:foreach(
                    fun
                        (Hook) when is_atom(Hook) ->
                            HookSamplingList = proplists:get_value(Hook, Sampler, []),
                            lists:foreach(
                                fun({StrCriterion, P}) ->
                                    vmq_events_sidecar_plugin:enable_sampling(
                                        Hook, list_to_binary(StrCriterion), P
                                    )
                                end,
                                HookSamplingList
                            );
                        (_) ->
                            lager:error("Hook must be an atom.")
                    end,
                    SamplingHooks
                ),

                GrpcPercentage = application:get_env(
                    vmq_events_sidecar, grpc_percentage, 0
                ),
                vmq_events_sidecar_plugin:set_grpc_percentage(
                    effective_grpc_percentage(GrpcPercentage)
                ),

                UserType = application:get_env(vmq_events_sidecar, user_type, "default"),
                persistent_term:put(?GRPC_USER_TYPE, list_to_binary(UserType)),
                GrpcTimeout = application:get_env(vmq_events_sidecar, grpc_timeout, 500),
                persistent_term:put(?GRPC_TIMEOUT, GrpcTimeout)
            end),
            Ret;
        E ->
            E
    end.

%%====================================================================
%% Supervisor callbacks
%%====================================================================

%% Child :: {Id,StartFunc,Restart,Shutdown,Type,Modules}
init([]) ->
    %% intensity 1 / period 5 would be too tight now that a child supervises a
    %% whole worker pool: one transient blip there would escalate to killing the
    %% metrics and plugin gen_servers, and with them the shackle path that still
    %% carries production traffic during the rollout.
    SupFlags =
        #{strategy => one_for_one, intensity => 5, period => 10},
    ChildSpecs =
        [
            %% Must start before the workers -- it owns the tables they write to.
            #{
                id => vmq_events_sidecar_metrics,
                start => {vmq_events_sidecar_metrics, start_link, []},
                restart => permanent,
                type => worker,
                modules => [vmq_events_sidecar_metrics]
            },
            #{
                id => vmq_events_sidecar_plugin,
                start => {vmq_events_sidecar_plugin, start_link, []},
                restart => permanent,
                type => worker,
                modules => [vmq_events_sidecar_plugin]
            }
        ],

    Hostname = application:get_env(vmq_events_sidecar, hostname, "127.0.0.1"),
    Port = application:get_env(vmq_events_sidecar, port, 8890),
    PoolSize = application:get_env(vmq_events_sidecar, pool_size, 100),
    BacklogSize = application:get_env(vmq_events_sidecar, backlog_size, 4096),

    ClientOpts = [
        {address, Hostname},
        {port, Port},
        {protocol, shackle_tcp}
    ],
    PoolOtps = [
        {backlog_size, BacklogSize},
        {pool_size, PoolSize}
    ],
    ok = shackle_pool:start(?APP, ?CLIENT, ClientOpts, PoolOtps),

    %% The gRPC channel pool and the worker pool are both gated on grpc_endpoint,
    %% so a deployment that has not enabled gRPC starts exactly the processes it
    %% started before this path existed.
    GrpcChildSpecs =
        case grpc_endpoint() of
            "" ->
                [];
            GrpcEndpoint ->
                GrpcPort = application:get_env(vmq_events_sidecar, grpc_port, 80),
                GrpcPoolSize = application:get_env(vmq_events_sidecar, grpc_pool_size, 100),
                ok = vmq_events_sidecar_grpc_client:start(#{
                    endpoint => GrpcEndpoint,
                    port => GrpcPort,
                    pool_size => GrpcPoolSize
                }),
                [
                    #{
                        id => vmq_events_sidecar_grpc_worker_sup,
                        start => {vmq_events_sidecar_grpc_worker_sup, start_link, []},
                        restart => permanent,
                        type => supervisor,
                        modules => [vmq_events_sidecar_grpc_worker_sup]
                    }
                ]
        end,

    {ok, {SupFlags, ChildSpecs ++ GrpcChildSpecs}}.

%%====================================================================
%% Internal functions
%%====================================================================

grpc_endpoint() ->
    application:get_env(vmq_events_sidecar, grpc_endpoint, "").

%% Routing to gRPC without an endpoint would send every event to a pool that was
%% never started. vmq_events_sidecar_cli already refuses this at runtime; boot
%% config needs the same guard.
effective_grpc_percentage(0) ->
    0;
effective_grpc_percentage(Percentage) ->
    case grpc_endpoint() of
        "" ->
            lager:warning(
                "ignoring grpc_percentage=~p because grpc_endpoint is not configured",
                [Percentage]
            ),
            0;
        _Endpoint ->
            Percentage
    end.
