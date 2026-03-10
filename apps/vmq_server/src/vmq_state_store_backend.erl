-module(vmq_state_store_backend).

-export([init/0, backend/0]).
-export([
    subscribe/4,
    delete_subscriber/2,
    unsubscribe/3,
    remap_subscriber/3,
    migrate_offline_queue/3,
    fetch_subscriber/2,
    fetch_matched_topic_subscribers/2,
    get_live_nodes/0,
    ensure_no_local_client/0,
    msg_store_write/2,
    msg_store_read/2,
    msg_store_delete/1,
    msg_store_pop/2,
    msg_store_find/1,
    enqueue_msg/4,
    poll_main_queue/3,
    reap_subscribers/2,
    load_reg_functions/0,
    load_msg_store_functions/0,
    load_queue_functions/2
]).

-callback subscribe(term(), term(), non_neg_integer(), list()) ->
    {ok, term()} | {error, term()}.
-callback delete_subscriber(term(), term()) -> ok.
-callback unsubscribe(term(), term(), list()) -> {ok, term()} | {error, term()}.
-callback remap_subscriber(term(), term(), boolean()) ->
    {ok, term()} | {error, term()}.
-callback migrate_offline_queue(term(), term(), node()) ->
    ok | {ok, term()} | {error, term()}.
-callback fetch_subscriber(term(), term()) -> {ok, term()} | {error, term()}.
-callback fetch_matched_topic_subscribers(term(), list()) -> {ok, term()} | {error, term()}.
-callback get_live_nodes() -> {ok, term()} | {error, term()}.
-callback ensure_no_local_client() -> {ok, binary()} | {error, term()}.
-callback msg_store_write(term(), term()) -> ok | {ok, term()} | {error, term()}.
-callback msg_store_read(term(), term()) -> {ok, term()} | {error, term()}.
-callback msg_store_delete(term()) -> ok | {ok, term()} | {error, term()}.
-callback msg_store_pop(term(), term()) -> ok | {ok, term()} | {error, term()}.
-callback msg_store_find(term()) -> ok | {ok, term()} | {error, term()}.
-callback enqueue_msg(atom(), string(), binary(), binary()) ->
    ok | {ok, term()} | {error, term()}.
-callback poll_main_queue(atom(), string(), non_neg_integer()) ->
    {ok, undefined} | {ok, list()} | {error, term()}.
-callback reap_subscribers(node(), non_neg_integer()) ->
    {ok, list()} | {ok, undefined} | {error, term()}.
-callback load_reg_functions() -> ok.
-callback load_msg_store_functions() -> ok.
-callback load_queue_functions(atom(), atom()) -> ok.

init() ->
    Backend =
        case application:get_env(vmq_server, redis_enabled, true) of
            true -> vmq_redis_store;
            false -> vmq_noop_store
        end,
    persistent_term:put(vmq_state_store_backend, Backend),
    ok.

backend() ->
    persistent_term:get(vmq_state_store_backend).

subscribe(MP, ClientId, NumOfTopics, UnwordedTopicsWithBinaryQoS) ->
    (backend()):subscribe(MP, ClientId, NumOfTopics, UnwordedTopicsWithBinaryQoS).

delete_subscriber(MP, ClientId) ->
    (backend()):delete_subscriber(MP, ClientId).

unsubscribe(MP, ClientId, SortedUnwordedTopics) ->
    (backend()):unsubscribe(MP, ClientId, SortedUnwordedTopics).

remap_subscriber(MP, ClientId, StartClean) ->
    (backend()):remap_subscriber(MP, ClientId, StartClean).

migrate_offline_queue(MP, ClientId, OldNode) ->
    (backend()):migrate_offline_queue(MP, ClientId, OldNode).

fetch_subscriber(MP, ClientId) ->
    (backend()):fetch_subscriber(MP, ClientId).

fetch_matched_topic_subscribers(MP, Topics) ->
    (backend()):fetch_matched_topic_subscribers(MP, Topics).

get_live_nodes() ->
    (backend()):get_live_nodes().

ensure_no_local_client() ->
    (backend()):ensure_no_local_client().

msg_store_write(SubscriberId, Msg) ->
    (backend()):msg_store_write(SubscriberId, Msg).

msg_store_read(SubscriberId, MsgRef) ->
    (backend()):msg_store_read(SubscriberId, MsgRef).

msg_store_delete(SubscriberId) ->
    (backend()):msg_store_delete(SubscriberId).

msg_store_pop(SubscriberId, MsgRef) ->
    (backend()):msg_store_pop(SubscriberId, MsgRef).

msg_store_find(SubscriberId) ->
    (backend()):msg_store_find(SubscriberId).

enqueue_msg(RedisClient, MainQueueKey, SubscriberBin, MsgBin) ->
    (backend()):enqueue_msg(RedisClient, MainQueueKey, SubscriberBin, MsgBin).

poll_main_queue(RedisClient, MainQueue, BatchSize) ->
    (backend()):poll_main_queue(RedisClient, MainQueue, BatchSize).

reap_subscribers(DeadNode, MaxClients) ->
    (backend()):reap_subscribers(DeadNode, MaxClients).

load_reg_functions() ->
    (backend()):load_reg_functions().

load_msg_store_functions() ->
    (backend()):load_msg_store_functions().

load_queue_functions(ProducerClient, ConsumerClient) ->
    (backend()):load_queue_functions(ProducerClient, ConsumerClient).
