-module(vmq_redis_store).

-behaviour(vmq_state_store_backend).

-include("vmq_server.hrl").

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
    load_reg_functions/0,
    load_msg_store_functions/0,
    load_queue_functions/2,
    ensure_reaper/1,
    del_reaper/1,
    get_reaper/1,
    enqueue/3
]).

%%%===================================================================
%%% Subscriber Registry
%%%===================================================================

subscribe(MP, ClientId, NumOfTopics, UnwordedTopicsWithBinaryQoS) ->
    vmq_redis:query(
        vmq_redis_client,
        [
            ?FCALL,
            ?SUBSCRIBE,
            0,
            MP,
            ClientId,
            node(),
            os:system_time(nanosecond),
            NumOfTopics
            | UnwordedTopicsWithBinaryQoS
        ],
        ?FCALL,
        ?SUBSCRIBE
    ).

delete_subscriber(MP, ClientId) ->
    vmq_redis:query(
        vmq_redis_client,
        [
            ?FCALL,
            ?DELETE_SUBSCRIBER,
            0,
            MP,
            ClientId,
            node(),
            os:system_time(nanosecond)
        ],
        ?FCALL,
        ?DELETE_SUBSCRIBER
    ),
    ok.

unsubscribe(MP, ClientId, SortedUnwordedTopics) ->
    vmq_redis:query(
        vmq_redis_client,
        [
            ?FCALL,
            ?UNSUBSCRIBE,
            0,
            MP,
            ClientId,
            node(),
            os:system_time(nanosecond),
            length(SortedUnwordedTopics)
            | SortedUnwordedTopics
        ],
        ?FCALL,
        ?UNSUBSCRIBE
    ).

remap_subscriber(MP, ClientId, StartClean) ->
    vmq_redis:query(
        vmq_redis_client,
        [
            ?FCALL,
            ?REMAP_SUBSCRIBER,
            0,
            MP,
            ClientId,
            node(),
            StartClean,
            os:system_time(nanosecond)
        ],
        ?FCALL,
        ?REMAP_SUBSCRIBER
    ).

migrate_offline_queue(MP, ClientId, OldNode) ->
    vmq_redis:query(
        vmq_redis_client,
        [
            ?FCALL,
            ?MIGRATE_OFFLINE_QUEUE,
            0,
            MP,
            ClientId,
            OldNode,
            node(),
            os:system_time(nanosecond)
        ],
        ?FCALL,
        ?MIGRATE_OFFLINE_QUEUE
    ).

%%%===================================================================
%%% Subscriber Lookup
%%%===================================================================

fetch_subscriber(MP, ClientId) ->
    vmq_redis:query(
        vmq_redis_client,
        [
            ?FCALL,
            ?FETCH_SUBSCRIBER,
            0,
            MP,
            ClientId
        ],
        ?FCALL,
        ?FETCH_SUBSCRIBER
    ).

fetch_matched_topic_subscribers(MP, Topics) ->
    UnwordedTopics = [vmq_topic:unword(T) || T <- Topics],
    vmq_redis:query(
        vmq_redis_client,
        [
            ?FCALL,
            ?FETCH_MATCHED_TOPIC_SUBSCRIBERS,
            0,
            MP,
            length(UnwordedTopics)
            | UnwordedTopics
        ],
        ?FCALL,
        ?FETCH_MATCHED_TOPIC_SUBSCRIBERS
    ).

%%%===================================================================
%%% Cluster Monitoring
%%%===================================================================

get_live_nodes() ->
    vmq_redis:query(
        vmq_redis_client,
        [
            ?FCALL,
            ?GET_LIVE_NODES,
            0,
            node()
        ],
        ?FCALL,
        ?GET_LIVE_NODES
    ).

ensure_no_local_client() ->
    vmq_redis:query(vmq_redis_client, ["SCARD", node()], ?SCARD, ?ENSURE_NO_LOCAL_CLIENT).

%%%===================================================================
%%% Message Store
%%%===================================================================

msg_store_write(SubscriberId, Msg) ->
    vmq_redis:query(
        vmq_message_store_redis_client,
        [
            ?FCALL,
            ?WRITE_OFFLINE_MESSAGE,
            1,
            term_to_binary(SubscriberId),
            term_to_binary(Msg)
        ],
        ?FCALL,
        ?WRITE_OFFLINE_MESSAGE
    ).

msg_store_read(_SubscriberId, _MsgRef) ->
    {error, not_supported}.

msg_store_delete(SubscriberId) ->
    vmq_redis:query(
        vmq_message_store_redis_client,
        [
            ?FCALL,
            ?DELETE_SUBS_OFFLINE_MESSAGES,
            1,
            term_to_binary(SubscriberId)
        ],
        ?FCALL,
        ?DELETE_SUBS_OFFLINE_MESSAGES
    ).

msg_store_pop(SubscriberId, _MsgRef) ->
    vmq_redis:query(
        vmq_message_store_redis_client,
        [
            ?FCALL,
            ?POP_OFFLINE_MESSAGE,
            1,
            term_to_binary(SubscriberId)
        ],
        ?FCALL,
        ?POP_OFFLINE_MESSAGE
    ).

msg_store_find(SubscriberId) ->
    vmq_redis:query(
        vmq_message_store_redis_client,
        ["LRANGE", term_to_binary(SubscriberId), "0", "-1"],
        ?FIND,
        ?MSG_STORE_FIND
    ).

%%%===================================================================
%%% Queue
%%%===================================================================

enqueue(Node, SubscriberBin, MsgBin) ->
    vmq_redis_queue:enqueue(Node, SubscriberBin, MsgBin).

%%%===================================================================
%%% Reaper
%%%===================================================================

ensure_reaper(Node) ->
    vmq_redis_reaper_sup:ensure_reaper(Node).

del_reaper(Node) ->
    vmq_redis_reaper_sup:del_reaper(Node).

get_reaper(Node) ->
    vmq_redis_reaper_sup:get_reaper(Node).

%%%===================================================================
%%% Initialization
%%%===================================================================

load_reg_functions() ->
    LuaDir = application:get_env(vmq_server, redis_lua_dir, "./etc/lua"),
    {ok, RemapSubscriberScript} = file:read_file(LuaDir ++ "/remap_subscriber.lua"),
    {ok, SubscribeScript} = file:read_file(LuaDir ++ "/subscribe.lua"),
    {ok, UnsubscribeScript} = file:read_file(LuaDir ++ "/unsubscribe.lua"),
    {ok, DeleteSubscriberScript} = file:read_file(LuaDir ++ "/delete_subscriber.lua"),
    {ok, FetchMatchedTopicSubscribersScript} = file:read_file(
        LuaDir ++ "/fetch_matched_topic_subscribers.lua"
    ),
    {ok, FetchSubscriberScript} = file:read_file(LuaDir ++ "/fetch_subscriber.lua"),
    {ok, GetLiveNodesScript} = file:read_file(LuaDir ++ "/get_live_nodes.lua"),
    {ok, MigrateOfflineQueueScript} = file:read_file(LuaDir ++ "/migrate_offline_queue.lua"),
    {ok, ReapSubscribersScript} = file:read_file(LuaDir ++ "/reap_subscribers.lua"),

    {ok, <<"remap_subscriber">>} = vmq_redis:query(
        vmq_redis_client,
        [?FUNCTION, "LOAD", "REPLACE", RemapSubscriberScript],
        ?FUNCTION_LOAD,
        ?REMAP_SUBSCRIBER
    ),
    {ok, <<"subscribe">>} = vmq_redis:query(
        vmq_redis_client,
        [?FUNCTION, "LOAD", "REPLACE", SubscribeScript],
        ?FUNCTION_LOAD,
        ?SUBSCRIBE
    ),
    {ok, <<"unsubscribe">>} = vmq_redis:query(
        vmq_redis_client,
        [?FUNCTION, "LOAD", "REPLACE", UnsubscribeScript],
        ?FUNCTION_LOAD,
        ?UNSUBSCRIBE
    ),
    {ok, <<"delete_subscriber">>} = vmq_redis:query(
        vmq_redis_client,
        [?FUNCTION, "LOAD", "REPLACE", DeleteSubscriberScript],
        ?FUNCTION_LOAD,
        ?DELETE_SUBSCRIBER
    ),
    {ok, <<"fetch_matched_topic_subscribers">>} = vmq_redis:query(
        vmq_redis_client,
        [?FUNCTION, "LOAD", "REPLACE", FetchMatchedTopicSubscribersScript],
        ?FUNCTION_LOAD,
        ?FETCH_MATCHED_TOPIC_SUBSCRIBERS
    ),
    {ok, <<"fetch_subscriber">>} = vmq_redis:query(
        vmq_redis_client,
        [?FUNCTION, "LOAD", "REPLACE", FetchSubscriberScript],
        ?FUNCTION_LOAD,
        ?FETCH_SUBSCRIBER
    ),
    {ok, <<"get_live_nodes">>} = vmq_redis:query(
        vmq_redis_client,
        [?FUNCTION, "LOAD", "REPLACE", GetLiveNodesScript],
        ?FUNCTION_LOAD,
        ?GET_LIVE_NODES
    ),
    {ok, <<"migrate_offline_queue">>} = vmq_redis:query(
        vmq_redis_client,
        [?FUNCTION, "LOAD", "REPLACE", MigrateOfflineQueueScript],
        ?FUNCTION_LOAD,
        ?MIGRATE_OFFLINE_QUEUE
    ),
    {ok, <<"reap_subscribers">>} = vmq_redis:query(
        vmq_redis_client,
        [?FUNCTION, "LOAD", "REPLACE", ReapSubscribersScript],
        ?FUNCTION_LOAD,
        ?REAP_SUBSCRIBERS
    ),
    ok.

load_msg_store_functions() ->
    LuaDir = application:get_env(vmq_server, redis_lua_dir, "./etc/lua"),

    {ok, PopOfflineMessageScript} = file:read_file(LuaDir ++ "/pop_offline_message.lua"),
    {ok, WriteOfflineMessageScript} = file:read_file(
        LuaDir ++ "/write_offline_message.lua"
    ),
    {ok, DeleteSubsOfflineMessagesScript} = file:read_file(
        LuaDir ++ "/delete_subs_offline_messages.lua"
    ),

    {ok, <<"pop_offline_message">>} = vmq_redis:query(
        vmq_message_store_redis_client,
        [?FUNCTION, "LOAD", "REPLACE", PopOfflineMessageScript],
        ?FUNCTION_LOAD,
        ?POP_OFFLINE_MESSAGE
    ),
    {ok, <<"write_offline_message">>} = vmq_redis:query(
        vmq_message_store_redis_client,
        [?FUNCTION, "LOAD", "REPLACE", WriteOfflineMessageScript],
        ?FUNCTION_LOAD,
        ?WRITE_OFFLINE_MESSAGE
    ),
    {ok, <<"delete_subs_offline_messages">>} = vmq_redis:query(
        vmq_message_store_redis_client,
        [?FUNCTION, "LOAD", "REPLACE", DeleteSubsOfflineMessagesScript],
        ?FUNCTION_LOAD,
        ?DELETE_SUBS_OFFLINE_MESSAGES
    ),
    ok.

load_queue_functions(ProducerClient, ConsumerClient) ->
    LuaDir = application:get_env(vmq_server, redis_lua_dir, "./etc/lua"),
    {ok, EnqueueMsgScript} = file:read_file(LuaDir ++ "/enqueue_msg.lua"),
    {ok, PollMainQueueScript} = file:read_file(LuaDir ++ "/poll_main_queue.lua"),

    {ok, <<"enqueue_msg">>} = eredis:q(ProducerClient, [
        ?FUNCTION, "LOAD", "REPLACE", EnqueueMsgScript
    ]),
    {ok, <<"poll_main_queue">>} = eredis:q(ConsumerClient, [
        ?FUNCTION, "LOAD", "REPLACE", PollMainQueueScript
    ]),
    ok.
