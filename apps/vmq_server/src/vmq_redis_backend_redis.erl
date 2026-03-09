-module(vmq_redis_backend_redis).

-behaviour(vmq_redis_backend).

-include("vmq_server.hrl").

-import(vmq_subscriber, [check_format/1]).

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

%%%===================================================================
%%% Subscriber Registry
%%%===================================================================

subscribe(MP, ClientId, NumOfTopics, UnwordedTopicsWithBinaryQoS) ->
    case
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
        )
    of
        {ok, [_, CS, NTWQ]} ->
            CleanSessionBool =
                case CS of
                    <<"1">> -> true;
                    undefined -> false
                end,
            NewTopicsWithQoS = [
                {vmq_topic:word(Topic), binary_to_term(QoS)}
             || [Topic, QoS] <- NTWQ
            ],
            {ok, [{node(), CleanSessionBool, NewTopicsWithQoS}]};
        {ok, []} ->
            {ok, []};
        {ok, _} ->
            {error, unwanted_redis_response};
        Err ->
            Err
    end.

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
    case
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
        )
    of
        {ok, <<"1">>} -> ok;
        {ok, _} -> {error, unwanted_redis_response};
        Err -> Err
    end.

remap_subscriber(MP, ClientId, true) ->
    Subs = vmq_subscriber:new(true),
    case
        vmq_redis:query(
            vmq_redis_client,
            [
                ?FCALL,
                ?REMAP_SUBSCRIBER,
                0,
                MP,
                ClientId,
                node(),
                true,
                os:system_time(nanosecond)
            ],
            ?FCALL,
            ?REMAP_SUBSCRIBER
        )
    of
        {ok, [undefined, [_, <<"1">>, []]]} -> {false, Subs, []};
        {ok, [<<"1">>, [_, <<"1">>, []]]} -> {true, Subs, []};
        {ok, [<<"1">>, [_, <<"1">>, []], OldNode]} -> {true, Subs, [binary_to_atom(OldNode)]};
        {ok, _} -> {error, unwanted_redis_response};
        Err -> Err
    end;
remap_subscriber(MP, ClientId, false) ->
    case
        vmq_redis:query(
            vmq_redis_client,
            [
                ?FCALL,
                ?REMAP_SUBSCRIBER,
                0,
                MP,
                ClientId,
                node(),
                false,
                os:system_time(nanosecond)
            ],
            ?FCALL,
            ?REMAP_SUBSCRIBER
        )
    of
        {ok, [undefined, [NewNode, undefined, []]]} ->
            {false, [{binary_to_atom(NewNode), false, []}], []};
        {ok, [<<"1">>, [NewNode, undefined, TopicsWithQoS]]} ->
            NewTopicsWithQoS = [
                {vmq_topic:word(Topic), binary_to_term(QoS)}
             || [Topic, QoS] <- TopicsWithQoS
            ],
            {true, [{binary_to_atom(NewNode), false, NewTopicsWithQoS}], []};
        {ok, [<<"1">>, [NewNode, undefined, TopicsWithQoS], OldNode]} ->
            NewTopicsWithQoS = [
                {vmq_topic:word(Topic), binary_to_term(QoS)}
             || [Topic, QoS] <- TopicsWithQoS
            ],
            NewSubs = [{binary_to_atom(NewNode), false, NewTopicsWithQoS}],
            {true, NewSubs, [binary_to_atom(OldNode)]};
        {ok, _} ->
            {error, unwanted_redis_response};
        Err ->
            Err
    end.

migrate_offline_queue(MP, ClientId, OldNode) ->
    case
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
        )
    of
        {ok, undefined} ->
            {error, client_does_not_exist};
        {ok, NodeBin} when is_binary(NodeBin) ->
            {ok, binary_to_atom(NodeBin)};
        Res ->
            lager:warning("migrate_offline_queue unexpected: ~p", [Res]),
            {error, unwanted_response}
    end.

%%%===================================================================
%%% Subscriber Lookup
%%%===================================================================

fetch_subscriber(MP, ClientId) ->
    case
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
        )
    of
        {ok, []} ->
            not_found;
        {ok, [NodeBinary, CS, TopicsWithQoSBinary]} ->
            CleanSession =
                case CS of
                    <<"1">> -> true;
                    _ -> false
                end,
            TopicsWithQoS = [
                {vmq_topic:word(Topic), binary_to_term(QoS)}
             || [Topic, QoS] <- TopicsWithQoSBinary
            ],
            {ok, check_format([{binary_to_atom(NodeBinary), CleanSession, TopicsWithQoS}])};
        _ ->
            not_found
    end.

fetch_matched_topic_subscribers(MP, Topics) ->
    UnwordedTopics = [vmq_topic:unword(T) || T <- Topics],
    case
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
        )
    of
        {ok, SubscribersList} -> SubscribersList;
        Err -> Err
    end.

%%%===================================================================
%%% Cluster Monitoring
%%%===================================================================

get_live_nodes() ->
    case
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
        )
    of
        {ok, LiveNodes} when is_list(LiveNodes) ->
            {ok, LiveNodes};
        {ok, Other} ->
            {error, {unexpected_response, Other}};
        {error, _} = Err ->
            Err
    end.

ensure_no_local_client() ->
    vmq_redis:query(vmq_redis_client, ["SCARD", node()], ?SCARD, ?ENSURE_NO_LOCAL_CLIENT).

%%%===================================================================
%%% Message Store
%%%===================================================================

msg_store_write(SubscriberId, Msg) ->
    case
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
        )
    of
        {ok, OfflineMsgCount} ->
            {ok, binary_to_integer(OfflineMsgCount)};
        {error, _} ->
            {error, not_supported}
    end.

msg_store_read(_SubscriberId, _MsgRef) ->
    {error, not_supported}.

msg_store_delete(SubscriberId) ->
    case
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
        )
    of
        {ok, OfflineMsgCount} ->
            {ok, binary_to_integer(OfflineMsgCount)};
        {error, _} ->
            {error, not_supported}
    end.

msg_store_pop(SubscriberId, _MsgRef) ->
    case
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
        )
    of
        {ok, OfflineMsgCount} ->
            {ok, binary_to_integer(OfflineMsgCount)};
        {error, _} ->
            {error, not_supported}
    end.

msg_store_find(SubscriberId) ->
    case
        vmq_redis:query(
            vmq_message_store_redis_client,
            ["LRANGE", term_to_binary(SubscriberId), "0", "-1"],
            ?FIND,
            ?MSG_STORE_FIND
        )
    of
        {ok, MsgsInB} ->
            DMsgs = lists:foldr(
                fun(MsgB, Acc) ->
                    Msg = binary_to_term(MsgB),
                    D = #deliver{msg = Msg, qos = Msg#vmq_msg.qos},
                    [D | Acc]
                end,
                [],
                MsgsInB
            ),
            {ok, DMsgs};
        Res ->
            Res
    end.

%%%===================================================================
%%% Main Queue
%%%===================================================================

enqueue_msg(RedisClient, MainQueueKey, SubscriberBin, MsgBin) ->
    case
        vmq_redis:query(
            RedisClient,
            [
                ?FCALL,
                ?ENQUEUE_MSG,
                1,
                MainQueueKey,
                SubscriberBin,
                MsgBin
            ],
            ?FCALL,
            ?ENQUEUE_MSG
        )
    of
        {ok, MainQueueSize} ->
            {ok, binary_to_integer(MainQueueSize)};
        {error, _} = Err ->
            Err
    end.

poll_main_queue(RedisClient, MainQueue, BatchSize) ->
    vmq_redis:query(
        RedisClient,
        [
            ?FCALL,
            ?POLL_MAIN_QUEUE,
            1,
            MainQueue,
            BatchSize
        ],
        ?FCALL,
        ?POLL_MAIN_QUEUE
    ).

%%%===================================================================
%%% Reaper
%%%===================================================================

reap_subscribers(DeadNode, MaxClients) ->
    vmq_redis:query(
        vmq_redis_client,
        [
            ?FCALL,
            ?REAP_SUBSCRIBERS,
            0,
            DeadNode,
            node(),
            MaxClients
        ],
        ?FCALL,
        ?REAP_SUBSCRIBERS
    ).

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
