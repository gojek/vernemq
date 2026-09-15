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
    %% metrics and plugin gen_servers, and with them the transport that carries
    %% events.
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
    %% grpc_enabled is the only switch: gRPC replaces the TCP path rather than
    %% running beside it, so exactly one of the two is ever created.
    GrpcChildSpecs =
        case vmq_events_sidecar_grpc_client:enabled() of
            false ->
                warn_if_enabled_without_endpoint(),
                ok = shackle_pool:start(?APP, ?CLIENT, ClientOpts, PoolOtps),
                persistent_term:put(?EVENTS_TRANSPORT, tcp),
                [];
            true ->
                GrpcEndpoint = grpc_endpoint(),
                GrpcPort = application:get_env(vmq_events_sidecar, grpc_port, 80),
                GrpcPoolSize = application:get_env(vmq_events_sidecar, grpc_pool_size, 100),
                ok = vmq_events_sidecar_grpc_client:start(#{
                    endpoint => GrpcEndpoint,
                    port => GrpcPort,
                    pool_size => GrpcPoolSize
                }),
                persistent_term:put(?EVENTS_TRANSPORT, grpc),
                [
                    #{
                        id => vmq_events_sidecar_grpc_worker_sup,
                        start => {vmq_events_sidecar_grpc_worker_sup, start_link, []},
                        restart => permanent,
                        type => supervisor,
                        modules => [vmq_events_sidecar_grpc_worker_sup]
                    },
                    #{
                        id => vmq_events_sidecar_grpc_conn_monitor,
                        start => {vmq_events_sidecar_grpc_conn_monitor, start_link, []},
                        restart => permanent,
                        type => worker,
                        modules => [vmq_events_sidecar_grpc_conn_monitor]
                    }
                ]
        end,

    {ok, {SupFlags, ChildSpecs ++ GrpcChildSpecs}}.

%%====================================================================
%% Internal functions
%%====================================================================

grpc_endpoint() ->
    application:get_env(vmq_events_sidecar, grpc_endpoint, "").

%% grpc_enabled on with no endpoint is a misconfiguration rather than a way to
%% switch the path off, so it is worth a boot-time error either way.
warn_if_enabled_without_endpoint() ->
    case application:get_env(vmq_events_sidecar, grpc_enabled, false) of
        true ->
            lager:error(
                "grpc_enabled is on but grpc_endpoint is not configured, "
                "the gRPC path stays disabled"
            );
        false ->
            ok
    end.
