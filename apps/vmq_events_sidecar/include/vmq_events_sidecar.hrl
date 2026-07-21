-ifndef(VERNEMQ_EVENTS_SIDECAR_HRL).
-define(VERNEMQ_EVENTS_SIDECAR_HRL, true).
-define(APP, vmq_events_sidecar).
-define(CLIENT, vmq_events_sidecar_client).
-define(GRPC_CHANNEL, vmq_events_sidecar_grpc_channel).
-define(GRPC_ROLLOUT_PERCENTAGE, vmq_events_sidecar_grpc_rollout_percentage).
-define(GRPC_USER_TYPE, vmq_events_sidecar_grpc_user_type).
-define(GRPC_TIMEOUT, vmq_events_sidecar_grpc_timeout).
-define(GRPC_INFLIGHT_COUNTER, vmq_events_sidecar_grpc_inflight_counter).

%% types
-type event() :: {atom(), integer(), tuple()}.
-type pool_size() :: pos_integer().
-type reason() :: atom().
-endif.
