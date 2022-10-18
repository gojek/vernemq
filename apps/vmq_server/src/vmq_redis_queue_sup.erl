-module(vmq_redis_queue_sup).
-author("dhruvjain").

-include("vmq_server.hrl").

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).

%%====================================================================
%% API functions
%%====================================================================

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

%%====================================================================
%% Supervisor callbacks
%%====================================================================

%% Child :: {Id,StartFunc,Restart,Shutdown,Type,Modules}
init(_) ->
    ClusterEndpoints = vmq_schema_util:parse_list(application:get_env(vmq_server,
                                                                      redis_queue_shard_endpoints,
                                                                      "[{\"127.0.0.1\", 6379}]"
                                                                      )),
    Opts = vmq_schema_util:parse_list(application:get_env(vmq_server, redis_queue_opts, "[{database, 1}]")),
    NumEndpoints = init_redis(ClusterEndpoints, Opts, 0),

    NumMainQWorkers = num_main_q_workers_per_redis_node(),
    SupFlags =
        {one_for_one, 5, 5},
    ChildSpec =
        fun(RegName, Client) ->
            {RegName,
                {vmq_redis_queue, start_link, [RegName, Client]},
                permanent, 5000, worker, [vmq_redis_queue]}
        end,

    ChildSpecs =
        [ChildSpec(
            gen_main_queue_worker_id(N), gen_redis_client_name(N div NumMainQWorkers, ?CONSUMER))
            || N <- lists:seq(0, NumMainQWorkers*NumEndpoints - 1)],
    {ok, {SupFlags, ChildSpecs}}.
%%====================================================================
%% Internal functions
%%====================================================================
init_redis([], _Opts, Id) ->
    Id;
init_redis([{Host, Port} | ClusterEndpoints], Opts, Id) ->
    ProducerRedisClient = gen_redis_client_name(Id, ?PRODUCER),
    ConsumerRedisClient = gen_redis_client_name(Id, ?CONSUMER),
    {ok, _pid1} = eredis:start_link(Host, Port, [{name, {local, ProducerRedisClient}} | Opts]),
    {ok, _pid2} = eredis:start_link(Host, Port, [{name, {local, ConsumerRedisClient}} | Opts]),

    LuaDir = application:get_env(vmq_server, redis_lua_dir, "./etc/lua"),
    {ok, EnqueueMsgScript} = file:read_file(LuaDir ++ "/enqueue_msg.lua"),
    {ok, PollMainQueueScript} = file:read_file(LuaDir ++ "/poll_main_queue.lua"),

    {ok, <<"enqueue_msg">>} = eredis:q(ProducerRedisClient, [?FUNCTION, "LOAD", "REPLACE", EnqueueMsgScript]),
    {ok, <<"poll_main_queue">>} = eredis:q(ConsumerRedisClient, [?FUNCTION, "LOAD", "REPLACE", PollMainQueueScript]),

    init_redis(ClusterEndpoints, Opts, Id + 1).

num_main_q_workers_per_redis_node() ->
    application:get_env(vmq_server, main_queue_workers_per_redis_shard, 1).

gen_main_queue_worker_id(N) ->
    list_to_atom("vmq_redis_main_queue_worker_" ++ integer_to_list(N)).

gen_redis_client_name(N, Type) ->
    list_to_atom("redis_queue_" ++ Type ++ "_client_" ++ integer_to_list(N)).