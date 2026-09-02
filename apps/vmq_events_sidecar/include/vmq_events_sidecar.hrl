-ifndef(VERNEMQ_EVENTS_SIDECAR_HRL).
-define(VERNEMQ_EVENTS_SIDECAR_HRL, true).
-define(APP, vmq_events_sidecar).
-define(CLIENT, vmq_events_sidecar_client).
-define(GRPC_CHANNEL, vmq_events_sidecar_grpc_channel).
-define(GRPC_ROLLOUT_PERCENTAGE, vmq_events_sidecar_grpc_rollout_percentage).
-define(GRPC_USER_TYPE, vmq_events_sidecar_grpc_user_type).
-define(GRPC_TIMEOUT, vmq_events_sidecar_grpc_timeout).

%% gRPC worker pool. All four are published by
%% vmq_events_sidecar_grpc_worker_sup:init/1 before its children start, and read
%% on the path by vmq_events_sidecar_grpc_dispatcher.
-define(GRPC_WORKER_NAMES, vmq_events_sidecar_grpc_worker_names).
-define(GRPC_RR_COUNTER, vmq_events_sidecar_grpc_rr_counter).
-define(GRPC_MAX_QUEUE_LEN, vmq_events_sidecar_grpc_max_queue_len).
-define(GRPC_DEPTH_COUNTERS, vmq_events_sidecar_grpc_depth_counters).

%% types
-type event() :: {atom(), integer(), tuple()}.
-type pool_size() :: pos_integer().
-type reason() :: atom().
-endif.
