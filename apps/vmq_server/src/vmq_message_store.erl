-module(vmq_message_store).

-behaviour(supervisor).

-include("vmq_server.hrl").

%% Supervisor callbacks
-export([init/1]).

%% API
-export([
    start/0,
    write/2,
    read/2,
    delete/1,
    delete/2,
    find/1,
    nr_of_offline_messages/0
]).

-define(OFFLINE_MESSAGES, offline_messages).

start() ->
    Ret = supervisor:start_link({local, ?MODULE}, ?MODULE, []),
    vmq_state_store_backend:load_msg_store_functions(),
    Ret.

write(SubscriberId, Msg) ->
    case vmq_state_store_backend:msg_store_write(SubscriberId, Msg) of
        ok ->
            ok;
        {ok, OfflineMsgCount} ->
            ets:insert(?OFFLINE_MESSAGES, {count, binary_to_integer(OfflineMsgCount)});
        {error, _} ->
            {error, not_supported}
    end.

read(_SubscriberId, _MsgRef) ->
    {error, not_supported}.

delete(SubscriberId) ->
    case vmq_state_store_backend:msg_store_delete(SubscriberId) of
        ok ->
            ok;
        {ok, OfflineMsgCount} ->
            ets:insert(?OFFLINE_MESSAGES, {count, binary_to_integer(OfflineMsgCount)});
        {error, _} ->
            {error, not_supported}
    end.

delete(SubscriberId, MsgRef) ->
    case vmq_state_store_backend:msg_store_pop(SubscriberId, MsgRef) of
        {ok, OfflineMsgCount} ->
            ets:insert(?OFFLINE_MESSAGES, {count, binary_to_integer(OfflineMsgCount)});
        {error, _} ->
            {error, not_supported}
    end.

find(SubscriberId) ->
    case vmq_state_store_backend:msg_store_find(SubscriberId) of
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

nr_of_offline_messages() ->
    case ets:lookup(?OFFLINE_MESSAGES, count) of
        [] -> 0;
        [{count, Count}] -> Count
    end.

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================

-spec init([]) ->
    {'ok',
        {{'one_for_one', 5, 10}, [
            {atom(), {atom(), atom(), list()}, permanent, pos_integer(), worker, [atom()]}
        ]}}.
init([]) ->
    ets:new(?OFFLINE_MESSAGES, [named_table, public, {write_concurrency, true}]),

    case application:get_env(vmq_server, redis_enabled, true) of
        false ->
            {ok, {{one_for_one, 5, 10}, []}};
        true ->
            init_with_redis()
    end.

init_with_redis() ->
    StoreCfgs = application:get_env(vmq_server, message_store, [
        {redis, [
            {connect_options, "[{sentinel, [{endpoints, [{\"localhost\", 26379}]}]},{database,2}]"}
        ]}
    ]),
    Redis = proplists:get_value(redis, StoreCfgs),
    Username =
        case proplists:get_value(username, Redis, undefined) of
            undefined -> undefined;
            User when is_atom(User) -> atom_to_list(User)
        end,
    Password =
        case proplists:get_value(password, Redis, undefined) of
            undefined -> undefined;
            Pass when is_atom(Pass) -> atom_to_list(Pass)
        end,

    {ok,
        {{one_for_one, 5, 10}, [
            {eredis,
                {eredis, start_link, [
                    [
                        {username, Username},
                        {password, Password},
                        {name, {local, vmq_message_store_redis_client}}
                        | vmq_schema_util:parse_list(proplists:get_value(connect_options, Redis))
                    ]
                ]},
                permanent, 5000, worker, [eredis]}
        ]}}.
