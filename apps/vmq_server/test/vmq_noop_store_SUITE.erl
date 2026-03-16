-module(vmq_noop_store_SUITE).

-include_lib("vmq_commons/include/vmq_types.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    t_subscribe/1,
    t_delete_subscriber/1,
    t_unsubscribe/1,
    t_remap_subscriber/1,
    t_migrate_offline_queue/1,
    t_fetch_subscriber/1,
    t_fetch_matched_topic_subscribers/1,
    t_get_live_nodes/1,
    t_ensure_no_local_client/1,
    t_msg_store_write/1,
    t_msg_store_read/1,
    t_msg_store_delete/1,
    t_msg_store_pop/1,
    t_msg_store_find/1,
    t_enqueue/1,
    t_load_reg_functions/1,
    t_load_msg_store_functions/1,
    t_load_queue_functions/1,
    t_ensure_reaper/1,
    t_del_reaper/1,
    t_get_reaper/1
]).

-define(MP, "").
-define(CLIENT_ID, <<"client_id">>).

all() ->
    [
        t_subscribe,
        t_delete_subscriber,
        t_unsubscribe,
        t_remap_subscriber,
        t_migrate_offline_queue,
        t_fetch_subscriber,
        t_fetch_matched_topic_subscribers,
        t_get_live_nodes,
        t_ensure_no_local_client,
        t_msg_store_write,
        t_msg_store_read,
        t_msg_store_delete,
        t_msg_store_pop,
        t_msg_store_find,
        t_enqueue,
        t_load_reg_functions,
        t_load_msg_store_functions,
        t_load_queue_functions,
        t_ensure_reaper,
        t_del_reaper,
        t_get_reaper
    ].

init_per_suite(Config) ->
    {ok, _} = vmq_metrics:start_link(),
    application:set_env(vmq_server, redis_enabled, false),
    vmq_state_store_backend:init(),
    Config.

end_per_suite(_Config) ->
    vmq_metrics:reset_counters(),
    ok.

t_subscribe(_C) ->
    {ok, []} = vmq_state_store_backend:subscribe(?MP, ?CLIENT_ID, 0, []).

t_delete_subscriber(_C) ->
    ok = vmq_state_store_backend:delete_subscriber(?MP, ?CLIENT_ID).

t_unsubscribe(_C) ->
    {ok, _} = vmq_state_store_backend:unsubscribe(?MP, ?CLIENT_ID, []).

t_remap_subscriber(_C) ->
    {ok, _} = vmq_state_store_backend:remap_subscriber(?MP, ?CLIENT_ID, true),
    {ok, _} = vmq_state_store_backend:remap_subscriber(?MP, ?CLIENT_ID, false).

t_migrate_offline_queue(_C) ->
    {ok, _} = vmq_state_store_backend:migrate_offline_queue(?MP, ?CLIENT_ID, node()).

t_fetch_subscriber(_C) ->
    {ok, []} = vmq_state_store_backend:fetch_subscriber(?MP, ?CLIENT_ID).

t_fetch_matched_topic_subscribers(_C) ->
    {ok, []} = vmq_state_store_backend:fetch_matched_topic_subscribers(?MP, []).

t_get_live_nodes(_C) ->
    {ok, _} = vmq_state_store_backend:get_live_nodes().

t_ensure_no_local_client(_C) ->
    {ok, _} = vmq_state_store_backend:ensure_no_local_client().

t_msg_store_write(_C) ->
    {ok, _} = vmq_state_store_backend:msg_store_write({?MP, ?CLIENT_ID}, #vmq_msg{}).

t_msg_store_read(_C) ->
    {error, not_found} = vmq_state_store_backend:msg_store_read({?MP, ?CLIENT_ID}, <<"msgref">>).

t_msg_store_delete(_C) ->
    {ok, _} = vmq_state_store_backend:msg_store_delete({?MP, ?CLIENT_ID}).

t_msg_store_pop(_C) ->
    {ok, _} = vmq_state_store_backend:msg_store_pop({?MP, ?CLIENT_ID}, <<"msgref">>).

t_msg_store_find(_C) ->
    {ok, []} = vmq_state_store_backend:msg_store_find({?MP, ?CLIENT_ID}).

t_enqueue(_C) ->
    ok = vmq_state_store_backend:enqueue(node(), <<"sub">>, <<"msg">>).

t_load_reg_functions(_C) ->
    ok = vmq_state_store_backend:load_reg_functions().

t_load_msg_store_functions(_C) ->
    ok = vmq_state_store_backend:load_msg_store_functions().

t_load_queue_functions(_C) ->
    ok = vmq_state_store_backend:load_queue_functions(producerRedisClient, consumerRedisClient).

t_ensure_reaper(_C) ->
    ok = vmq_state_store_backend:ensure_reaper(node()).

t_del_reaper(_C) ->
    ok = vmq_state_store_backend:del_reaper(node()).

t_get_reaper(_C) ->
    {ok, _} = vmq_state_store_backend:get_reaper(node()).
