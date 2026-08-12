-module(vmq_events_sidecar_grpc_client).

-include("../include/vmq_events_sidecar.hrl").
-include_lib("vmq_proto/include/event_request_pb.hrl").
-include_lib("vmq_proto/include/any_pb.hrl").

-export([start/1, stop/0, send_event/2]).

-define(SERVICE_PATH, <<"/webhook.v1beta1.PluginService/Event">>).

-define(DEFAULT_GUN_OPTS, #{
    protocols => [http2],
    connect_timeout => 5000,
    retry => 5,
    retry_timeout => 5000,
    http2_opts => #{keepalive => 30000},
    tcp_opts => [{nodelay, true}]
}).

-spec start(#{endpoint := string(), port := integer(), pool_size := integer()}) -> ok.
start(#{endpoint := Endpoint, port := Port, pool_size := PoolSize}) ->
    URL = "http://" ++ Endpoint ++ ":" ++ integer_to_list(Port),
    {ok, _} = grpc_client_sup:create_channel_pool(
        ?GRPC_CHANNEL, URL, #{
            pool_size => PoolSize,
            gun_opts => ?DEFAULT_GUN_OPTS
        }
    ),
    ok.

-spec stop() -> ok.
stop() ->
    try
        grpc_client_sup:stop_channel_pool(?GRPC_CHANNEL)
    catch
        _:_ -> ok
    end,
    ok.

-spec send_event(atom(), #'Any'{}) -> ok | {error, term()}.
send_event(HookName, #'Any'{type_url = TypeUrl, value = Value}) ->
    GrpcAny = #'google.protobuf.Any'{type_url = TypeUrl, value = Value},
    EventRequestBin = event_request_pb:encode_msg(
        #'webhook.v1beta1.EventRequest'{event = GrpcAny}
    ),
    UserType = persistent_term:get(?GRPC_USER_TYPE, <<"default">>),
    Timeout = persistent_term:get(?GRPC_TIMEOUT, 500),
    Metadata = #{<<"user-type">> => UserType},
    Def = #{
        path => ?SERVICE_PATH,
        service => 'webhook.v1beta1.PluginService',
        message_type => <<"webhook.v1beta1.EventRequest">>,
        marshal => fun(X) -> X end,
        unmarshal => fun(_X) -> #{} end
    },
    Ts1 = vmq_util:ts(),
    Result = grpc_client:unary(
        Def,
        EventRequestBin,
        Metadata,
        #{
            channel => ?GRPC_CHANNEL,
            timeout => Timeout,
            key_dispatch => erlang:unique_integer()
        }
    ),
    Ts2 = vmq_util:ts(),
    HookLabel = atom_to_list(HookName),
    vmq_metrics:pretimed_measurement(
        {vmq_events_sidecar, grpc_response_time, [{hook, HookLabel}, {channel, "grpc"}]},
        Ts2 - Ts1
    ),
    case Result of
        {ok, _Response} ->
            vmq_events_sidecar_metrics:incr_grpc_call_result(HookName, ok),
            ok;
        {ok, _Response, _Metadata} ->
            vmq_events_sidecar_metrics:incr_grpc_call_result(HookName, ok),
            ok;
        {error, Reason} ->
            vmq_events_sidecar_metrics:incr_grpc_call_result(HookName, classify_error(Reason)),
            {error, Reason}
    end.

classify_error({StatusName, _Message}) when is_atom(StatusName) ->
    StatusName;
classify_error(_Reason) ->
    transport_error.
