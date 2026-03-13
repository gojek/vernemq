-module(vmq_noop_store).

-behaviour(vmq_state_store_backend).

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

subscribe(_MP, _ClientId, _NumOfTopics, _UnwordedTopicsWithBinaryQoS) -> {ok, []}.
delete_subscriber(_MP, _ClientId) -> ok.
unsubscribe(_MP, _ClientId, _SortedUnwordedTopics) -> {ok, <<"1">>}.
remap_subscriber(_MP, _ClientId, true) ->
    {ok, [undefined, [atom_to_binary(node()), <<"1">>, []]]};
remap_subscriber(_MP, _ClientId, false) ->
    {ok, [undefined, [atom_to_binary(node()), undefined, []]]}.
migrate_offline_queue(_MP, _ClientId, _OldNode) -> {ok, atom_to_binary(node())}.

fetch_subscriber(_MP, _ClientId) -> {ok, []}.
fetch_matched_topic_subscribers(_MP, _Topics) -> {ok, []}.

get_live_nodes() -> {ok, [atom_to_binary(node())]}.
ensure_no_local_client() -> {ok, <<"0">>}.

msg_store_write(_SubscriberId, _Msg) -> ok.
msg_store_read(_SubscriberId, _MsgRef) -> {error, not_found}.
msg_store_delete(_SubscriberId) -> ok.
msg_store_pop(_SubscriberId, _MsgRef) -> {ok, <<"0">>}.
msg_store_find(_SubscriberId) -> {ok, []}.

load_reg_functions() -> ok.
load_msg_store_functions() -> ok.
load_queue_functions(_ProducerClient, _ConsumerClient) -> ok.

ensure_reaper(_Node) -> ok.
del_reaper(_Node) -> ok.
get_reaper(_Node) -> {ok, self()}.

enqueue(_Node, _SubscriberBin, _MsgBin) -> ok.
