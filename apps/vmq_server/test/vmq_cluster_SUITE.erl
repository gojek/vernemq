-module(vmq_cluster_SUITE).
-export([
    %% suite/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_testcase/2,
    end_per_testcase/2,
    all/0
]).

-export([
    multiple_connect_test/1,
    multiple_connect_unclean_test/1,
    distributed_subscribe_test/1,
    racing_connect_test/1,
    racing_subscriber_test/1,
    aborted_queue_migration_test/1,
    cluster_self_leave_subscriber_reaper_test/1,
    cluster_dead_node_subscriber_reaper_test/1,
    cluster_dead_node_message_reaper_test/1,
    shared_subs_random_policy_test/1,
    shared_subs_random_policy_test_with_local_caching/1,
    shared_subs_random_policy_online_first_test/1,
    shared_subs_random_policy_online_first_test_with_local_caching/1,
    shared_subs_random_policy_all_offline_test/1,
    shared_subs_random_policy_all_offline_test_with_local_caching/1,
    shared_subs_prefer_local_policy_test/1,
    shared_subs_prefer_local_policy_test_with_local_caching/1,
    shared_subs_local_only_policy_test/1,
    shared_subs_local_only_policy_test_with_local_caching/1,
    shared_subs_random_policy_dead_node_message_reaper_test/1,
    cross_node_publish_subscribe/1,
    routing_table_survives_node_restart/1
]).

-export([
    hook_uname_password_success/5,
    hook_auth_on_publish/6,
    hook_auth_on_subscribe/3
]).

-define(stacktrace, try throw(foo) catch _:foo:Stacktrace -> Stacktrace end).

-compile(nowarn_deprecated_function).

-include_lib("common_test/include/ct.hrl").
-include_lib("kernel/include/inet.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("vmq_commons/include/vmq_types.hrl").
-include("src/vmq_server.hrl").

% %% ===================================================================
% %% common_test callbacks
% %% ===================================================================
init_per_suite(Config) ->
    S = vmq_test_utils:get_suite_rand_seed(),
    %lager:start(),
    %% this might help, might not...
    os:cmd(os:find_executable("epmd") ++ " -daemon"),
    {ok, Hostname} = inet:gethostname(),
    case net_kernel:start([list_to_atom("runner@" ++ Hostname), shortnames]) of
        {ok, _} -> ok;
        {error, {already_started, _}} -> ok
    end,
    lager:info("node name ~p", [node()]),
    [S | Config].

end_per_suite(_Config) ->
    application:stop(lager),
    _Config.

init_per_testcase(convert_new_msgs_to_old_format, Config) ->
    %% no setup necessary,
    Config;
init_per_testcase(Case, Config) ->
    {ok, RedisClient} = eredis:start_link([{host, "127.0.0.1"}, {reconnect_sleep, no_reconnect}]),
    eredis:q(RedisClient, ["FLUSHALL"]),
    vmq_test_utils:seed_rand(Config),
    Nodes = vmq_cluster_test_utils:pmap(
        fun({N, P}) ->
            {ok, Peer, Node} = vmq_cluster_test_utils:start_node(N, Config, Case),
            {ok, _} = rpc:call(
                Node,
                vmq_server_cmd,
                listener_start,
                [P, []]
            ),
            {Peer, Node, P}
        end,
        [
            {test1, 18883},
            {test2, 18884},
            {test3, 18885}
        ]
    ),
    {_, CoverNodes, _} = lists:unzip3(Nodes),
    {ok, _} = ct_cover:add_nodes(CoverNodes),
    [begin
         ok = rpc:call(Node, vmq_auth, register_hooks, []),
         Node
     end
     || {_, Node, _} <- Nodes],
    [{nodes, Nodes}, {nodenames, [test1, test2, test3]}, {redis_client, RedisClient} | Config].

end_per_testcase(convert_new_msgs_to_old_format, Config) ->
    %% no teardown necessary,
    Config;
end_per_testcase(_, Config) ->
    eredis:stop(proplists:get_value(redis_client, Config)),
    {_, NodeList} = lists:keyfind(nodes, 1, Config),
    {Nodes, Peers, _} = lists:unzip3(NodeList),
    vmq_cluster_test_utils:pmap(
        fun({Peer, Node}) ->
            vmq_cluster_test_utils:stop_peer(Peer, Node)
        end,
        lists:zip(Nodes, Peers)
    ),
    ok.

all() ->
    [
        shared_subs_random_policy_dead_node_message_reaper_test,
        multiple_connect_test,
        multiple_connect_unclean_test,
        distributed_subscribe_test,
        racing_connect_test,
        racing_subscriber_test,
        aborted_queue_migration_test,
        cluster_self_leave_subscriber_reaper_test,
        cluster_dead_node_subscriber_reaper_test,
        cluster_dead_node_message_reaper_test,
        shared_subs_random_policy_test,
        shared_subs_random_policy_test_with_local_caching,
        shared_subs_random_policy_online_first_test,
        %% This test has been skipped because with introduction of in-mem shared subscriptions cache, the test is not valid anymore
        %% shared_subs_random_policy_online_first_test_with_local_caching,
        shared_subs_random_policy_all_offline_test,
        shared_subs_random_policy_all_offline_test_with_local_caching,
        shared_subs_prefer_local_policy_test,
        shared_subs_prefer_local_policy_test_with_local_caching,
        shared_subs_local_only_policy_test,
        shared_subs_local_only_policy_test_with_local_caching,
        cross_node_publish_subscribe,
        routing_table_survives_node_restart
    ].

% %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% %%% Actual Tests
% %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
multiple_connect_test(Config) ->
    ok = ensure_cluster(Config),
    {_, Nodes} = lists:keyfind(nodes, 1, Config),
    NrOfConnects = 250,
    %rand:uniform(NrOfConnects),
    NrOfProcesses = NrOfConnects div 50,
    NrOfMsgsPerProcess = NrOfConnects div NrOfProcesses,
    publish(Nodes, NrOfProcesses, NrOfMsgsPerProcess),
    done = receive_times(done, NrOfProcesses),
    true = check_unique_client("connect-multiple", Nodes),
    Config.

wait_until_converged_fold(Fun, Init, ExpectedResult, Nodes) ->
    {_, NodeNames, _} = lists:unzip3(Nodes),
    vmq_cluster_test_utils:wait_until(
      fun() ->
              ExpectedResult =:= lists:foldl(Fun, Init, NodeNames)
      end, 60*2, 500).

wait_until_converged(Nodes, Fun, ExpectedReturn) ->
    {_, NodeNames, _} = lists:unzip3(Nodes),
    vmq_cluster_test_utils:wait_until(
        fun() ->
            lists:all(
                fun(X) -> X == true end,
                vmq_cluster_test_utils:pmap(
                    fun(Node) ->
                        ExpectedReturn == Fun(Node)
                    end,
                    NodeNames
                )
            )
        end,
        60 * 2,
        500
    ).

multiple_connect_unclean_test(Config) ->
    %% This test makes sure that a cs false subscriber can receive QoS
    %% 1 messages, one message at a time only acknowleding one message
    %% per connection.
    ok = ensure_cluster(Config),
    {_, Nodes} = lists:keyfind(nodes, 1, Config),
    Topic = "qos1/multiple/test",
    Connect = packet:gen_connect("connect-unclean", [
        {clean_session, false},
        {keepalive, 60}
    ]),
    Connack = packet:gen_connack(0),
    Subscribe = packet:gen_subscribe(123, Topic, 1),
    Suback = packet:gen_suback(123, 1),
    Disconnect = packet:gen_disconnect(),
    {_, RandomNode, RandomPort} = random_node(Nodes),
    {ok, Socket} = packet:do_client_connect(Connect, Connack, [{port, RandomPort}]),
    ok = gen_tcp:send(Socket, Subscribe),
    ok = packet:expect_packet(Socket, "suback", Suback),
    ok = gen_tcp:send(Socket, Disconnect),
    gen_tcp:close(Socket),
    Payloads = publish_random(Nodes, 20, Topic),
    ok = vmq_cluster_test_utils:wait_until(
        fun() ->
            StoredMsgs = rpc:call(
                RandomNode,
                vmq_reg,
                stored,
                [{"", <<"connect-unclean">>}]
            ),
            20 == StoredMsgs
        end,
        60,
        500
    ),
    ok = receive_publishes(Nodes, Topic, Payloads).

distributed_subscribe_test(Config) ->
    ok = ensure_cluster(Config),
    {_, Nodes} = lists:keyfind(nodes, 1, Config),
    Topic = "qos1/distributed/test",
    Sockets =
        [
            begin
                Connect = packet:gen_connect(
                    "connect-" ++ integer_to_list(Port),
                    [
                        {clean_session, true},
                        {keepalive, 60}
                    ]
                ),
                Connack = packet:gen_connack(0),
                Subscribe = packet:gen_subscribe(123, Topic, 1),
                Suback = packet:gen_suback(123, 1),
                {ok, Socket} = packet:do_client_connect(Connect, Connack, [{port, Port}]),
                ok = gen_tcp:send(Socket, Subscribe),
                ok = packet:expect_packet(Socket, "suback", Suback),
                Socket
            end
         || {_, _, Port} <- Nodes
        ],
    [PubSocket | Rest] = Sockets,
    Publish = packet:gen_publish(Topic, 1, <<"test-message">>, [{mid, 1}]),
    Puback = packet:gen_puback(1),
    ok = gen_tcp:send(PubSocket, Publish),
    ok = packet:expect_packet(PubSocket, "puback", Puback),
    _ = [
        begin
            ok = packet:expect_packet(Socket, "publish", Publish),
            ok = gen_tcp:send(Socket, Puback),
            gen_tcp:close(Socket)
        end
     || Socket <- Rest
    ],
    Config.

racing_connect_test(Config) ->
    ok = ensure_cluster(Config),
    {_, Nodes} = lists:keyfind(nodes, 1, Config),
    Connect = packet:gen_connect(
        "connect-racer",
        [
            {clean_session, false},
            {keepalive, 60}
        ]
    ),
    Pids =
        [
            begin
                Connack =
                    case I of
                        1 ->
                            %% no session present
                            packet:gen_connack(false, 0);
                        2 ->
                            %% second iteration, wait for all nodes to catch up
                            %% this is required to create proper connack
                            ok = wait_until_converged(
                                Nodes,
                                fun(N) ->
                                    case
                                        rpc:call(N, vmq_subscriber_db, read, [
                                            {"", <<"connect-racer">>}, undefined
                                        ])
                                    of
                                        undefined -> false;
                                        [{_, false, []}] -> true
                                    end
                                end,
                                true
                            ),
                            packet:gen_connack(true, 0);
                        _ ->
                            packet:gen_connack(true, 0)
                    end,
                spawn_link(
                    fun() ->
                        {_, _RandomNode, RandomPort} = random_node(Nodes),
                        {ok, Socket} = packet:do_client_connect(Connect, Connack, [
                            {port, RandomPort}
                        ]),
                        inet:setopts(Socket, [{active, true}]),
                        receive
                            {tcp_closed, Socket} ->
                                %% we should be kicked out by the subsequent client
                                ok;
                            {lastman, test_over} ->
                                ok;
                            M ->
                                exit({unknown_message, M})
                        end
                    end
                )
            end
         || I <- lists:seq(1, 25)
        ],

    LastManStanding = fun(F) ->
        case [Pid || Pid <- Pids, is_process_alive(Pid)] of
            [LastMan] ->
                LastMan;
            [] ->
                exit({no_session_left});
            _ ->
                timer:sleep(10),
                F(F)
        end
    end,
    LastMan = LastManStanding(LastManStanding),
    %% Tell the last process the test is over and wait for it to
    %% terminate before ending the test and tearing down the test
    %% nodes.
    LastManRef = monitor(process, LastMan),
    LastMan ! {lastman, test_over},
    receive
        {'DOWN', LastManRef, process, _, normal} ->
            ok
    after 3000 ->
        throw("no DOWN msg received from LastMan")
    end,
    Config.

aborted_queue_migration_test(Config) ->
    ok = ensure_cluster(Config),
    {_, [{_, Node, Port} | RestNodes] = _Nodes} = lists:keyfind(nodes, 1, Config),
    Connect = packet:gen_connect(
        "connect-aborter",
        [
            {clean_session, false},
            {keepalive, 60}
        ]
    ),
    Topic = "migration/abort/test",
    Subscribe = packet:gen_subscribe(123, Topic, 1),
    Suback = packet:gen_suback(123, 1),

    %% no session present
    Connack1 = packet:gen_connack(false, 0),
    {ok, Socket1} = packet:do_client_connect(Connect, Connack1, [{port, Port}]),
    ok = gen_tcp:send(Socket1, Subscribe),
    ok = packet:expect_packet(Socket1, "suback", Suback),
    gen_tcp:close(Socket1),
    %% publish 10 messages
    _Payloads = publish_random(RestNodes, 10, Topic),

    %% wait until the queue has all 10 messages stored
    ok = vmq_cluster_test_utils:wait_until(
        fun() ->
            {0, 0, 0, 1, 10} == rpc:call(Node, vmq_queue_sup_sup, summary, [])
        end,
        60,
        500
    ),

    %% connect and disconnect/exit right away
    {_, RandomNode, RandomPort} = random_node(RestNodes),
    {ok, Socket2} = gen_tcp:connect("localhost", RandomPort, [
        binary, {reuseaddr, true}, {active, false}, {packet, raw}
    ]),
    gen_tcp:send(Socket2, Connect),
    gen_tcp:close(Socket2),

    %% although the connect flow didn't finish properly (because we closed the
    %% connection right away) the messages MUST be migrated to the 'RandomNode'
    ok = vmq_cluster_test_utils:wait_until(
        fun() ->
            {0, 0, 0, 1, 10} == rpc:call(RandomNode, vmq_queue_sup_sup, summary, [])
        end,
        60,
        500
    ).

racing_subscriber_test(Config) ->
    ok = ensure_cluster(Config),
    {_, Nodes} = lists:keyfind(nodes, 1, Config),
    Connect = packet:gen_connect(
        "connect-racer",
        [
            {clean_session, false},
            {keepalive, 60}
        ]
    ),
    Topic = "racing/subscriber/test",
    Subscribe = packet:gen_subscribe(123, Topic, 1),
    Suback = packet:gen_suback(123, 1),
    Pids =
        [
            begin
                Connack =
                    case I of
                        1 ->
                            %% no session present
                            packet:gen_connack(false, 0);
                        2 ->
                            %% second iteration, wait for all nodes to catch up
                            %% this is required to create proper connack
                            ok = wait_until_converged(
                                Nodes,
                                fun(N) ->
                                    case
                                        rpc:call(N, vmq_subscriber_db, read, [
                                            {"", "connect-racer"}, []
                                        ])
                                    of
                                        [] -> false;
                                        [{_, false, _}] -> true
                                    end
                                end,
                                true
                            ),
                            packet:gen_connack(true, 0);
                        _ ->
                            packet:gen_connack(true, 0)
                    end,
                spawn_link(
                    fun() ->
                        {_, _RandomNode, RandomPort} = random_node(Nodes),
                        case packet:do_client_connect(Connect, Connack, [{port, RandomPort}]) of
                            {ok, Socket} ->
                                case gen_tcp:send(Socket, Subscribe) of
                                    ok ->
                                        case packet:expect_packet(Socket, "suback", Suback) of
                                            ok ->
                                                inet:setopts(Socket, [{active, true}]),
                                                receive
                                                    {tcp_closed, Socket} ->
                                                        %% we should be kicked out by the subsequent client
                                                        ok;
                                                    {lastman, test_over} ->
                                                        ok;
                                                    M ->
                                                        exit({unknown_message, M})
                                                end;
                                            {error, closed} ->
                                                ok
                                        end;
                                    {error, closed} ->
                                        %% it's possible that we can't even subscribe due to
                                        %% a racing subscriber
                                        ok
                                end;
                            {error, closed} ->
                                ok
                        end
                    end
                )
            end
         || I <- lists:seq(1, 25)
        ],

    LastManStanding = fun(F) ->
        case [Pid || Pid <- Pids, is_process_alive(Pid)] of
            [LastMan] ->
                LastMan;
            [] ->
                exit({no_session_left});
            _ ->
                timer:sleep(10),
                F(F)
        end
    end,
    LastMan = LastManStanding(LastManStanding),
    %% Tell the last process the test is over and wait for it to
    %% terminate before ending the test and tearing down the test
    %% nodes.
    LastManRef = monitor(process, LastMan),
    LastMan ! {lastman, test_over},
    receive
        {'DOWN', LastManRef, process, _, normal} ->
            ok
    after 3000 ->
        throw("no DOWN msg received from LastMan")
    end,
    Config.

cluster_self_leave_subscriber_reaper_test(Config) ->
    ok = ensure_cluster(Config),
    {_, [{_, Node, Port} | RestNodesWithPorts] = _Nodes} = lists:keyfind(nodes, 1, Config),
    {_, RestNodes, _} = lists:unzip3(RestNodesWithPorts),
    Topic = "cluster/leave/topic",
    ToMigrate = 8,
    %% create ToMigrate sessions
    [PubSocket | _] =
        _Sockets =
        [
            begin
                Connect = packet:gen_connect(
                    "connect-unclean-" ++ integer_to_list(I),
                    [
                        {clean_session, false},
                        {keepalive, 60}
                    ]
                ),
                Connack = packet:gen_connack(0),
                Subscribe = packet:gen_subscribe(123, Topic, 1),
                Suback = packet:gen_suback(123, 1),
                {ok, Socket} = packet:do_client_connect(Connect, Connack, [{port, Port}]),
                ok = gen_tcp:send(Socket, Subscribe),
                ok = packet:expect_packet(Socket, "suback", Suback),
                Socket
            end
         || I <- lists:seq(1, ToMigrate)
        ],
    _CleanSockets =
        [
            begin
                Connect = packet:gen_connect(
                    "connect-clean-" ++ integer_to_list(I),
                    [
                        {clean_session, true},
                        {keepalive, 60}
                    ]
                ),
                Connack = packet:gen_connack(0),
                Subscribe = packet:gen_subscribe(123, Topic, 1),
                Suback = packet:gen_suback(123, 1),
                {ok, Socket} = packet:do_client_connect(Connect, Connack, [{port, Port}]),
                ok = gen_tcp:send(Socket, Subscribe),
                ok = packet:expect_packet(Socket, "suback", Suback),
                Socket
            end
         || I <- lists:seq(1, ToMigrate)
        ],
    %% publish a message for every session
    Publish = packet:gen_publish(Topic, 1, <<"test-message">>, [{mid, 1}]),
    Puback = packet:gen_puback(1),
    ok = gen_tcp:send(PubSocket, Publish),
    ok = packet:expect_packet(PubSocket, "puback", Puback),
    ok = vmq_cluster_test_utils:wait_until(
        fun() ->
            {ToMigrate * 2, 0, 0, 0, 0} == rpc:call(Node, vmq_queue_sup_sup, summary, [])
        end,
        60,
        500
    ),
    %% Gracefully stopping node will disconnect all sessions and move all online messages to offline queue
    {ok, _} = rpc:call(Node, vmq_server_cmd, node_stop, []),
    %% check that the leave was propagated to the rest
    ok = wait_until_converged(
        RestNodesWithPorts,
        fun(N) ->
            lists:usort(rpc:call(N, vmq_cluster_mon, nodes, []))
        end,
        lists:usort(RestNodes)
    ),
    %% The disconnected sessions are migrated to the rest of the nodes 
    %% with the help of reapers
    %% As the clients don't reconnect (in this test), their sessions are offline
    ok = wait_until_converged_fold(
           fun(N, {AccQ, AccM}) ->
                   {_,_,_,Queues,Messages} = rpc:call(N, vmq_queue_sup_sup, summary, []),
                   {AccQ + Queues, AccM + Messages}
           end,
           {0, 0},
           {ToMigrate, ToMigrate},
           RestNodesWithPorts).

cluster_dead_node_subscriber_reaper_test(Config) ->
    ok = ensure_cluster(Config),
    {_, [{Peer, Node, Port} | RestNodesWithPorts] = _Nodes} = lists:keyfind(nodes, 1, Config),
    {_, RestNodes, _} = lists:unzip3(RestNodesWithPorts),
    Topic = "cluster/dead/topic",
    ToMigrate = 8,
    %% create ToMigrate unclean sessions
    [PubSocket | _] =
        _Sockets =
        [
            begin
                Connect = packet:gen_connect(
                    "connect-unclean-" ++ integer_to_list(I),
                    [
                        {clean_session, false},
                        {keepalive, 60}
                    ]
                ),
                Connack = packet:gen_connack(0),
                Subscribe = packet:gen_subscribe(123, Topic, 1),
                Suback = packet:gen_suback(123, 1),
                {ok, Socket} = packet:do_client_connect(Connect, Connack, [{port, Port}]),
                ok = gen_tcp:send(Socket, Subscribe),
                ok = packet:expect_packet(Socket, "suback", Suback),
                Socket
            end
         || I <- lists:seq(1, ToMigrate)
        ],
    _CleanSockets =
        [
            begin
                Connect = packet:gen_connect(
                    "connect-clean-" ++ integer_to_list(I),
                    [
                        {clean_session, true},
                        {keepalive, 60}
                    ]
                ),
                Connack = packet:gen_connack(0),
                Subscribe = packet:gen_subscribe(123, Topic, 1),
                Suback = packet:gen_suback(123, 1),
                {ok, Socket} = packet:do_client_connect(Connect, Connack, [{port, Port}]),
                ok = gen_tcp:send(Socket, Subscribe),
                ok = packet:expect_packet(Socket, "suback", Suback),
                Socket
            end
         || I <- lists:seq(1, ToMigrate)
        ],
    %% publish a message for every session
    Publish = packet:gen_publish(Topic, 1, <<"test-message">>, [{mid, 1}]),
    Puback = packet:gen_puback(1),
    ok = gen_tcp:send(PubSocket, Publish),
    ok = packet:expect_packet(PubSocket, "puback", Puback),
    ok = vmq_cluster_test_utils:wait_until(
        fun() ->
            {ToMigrate * 2, 0, 0, 0, 0} == rpc:call(Node, vmq_queue_sup_sup, summary, [])
        end,
        60,
        500
    ),
    %% Ungracefully stop node
    vmq_cluster_test_utils:stop_peer(Peer, Node),
    %% check that the leave was propagated to the rest
    ok = wait_until_converged(
        RestNodesWithPorts,
        fun(N) ->
            lists:usort(rpc:call(N, vmq_cluster_mon, nodes, []))
        end,
        lists:usort(RestNodes)
    ),
    %% The disconnected sessions are migrated to the rest of the nodes 
    %% with the help of reapers
    %% As the clients don't reconnect (in this test), their sessions are offline
    %% Due to ungraceful shutdown, online messages were lost
    ok = wait_until_converged_fold(
           fun(N, {AccQ, _AccM}) ->
                   {_,_,_,Queues,_Messages} = rpc:call(N, vmq_queue_sup_sup, summary, []),
                   {AccQ + Queues, 0}
           end,
           {0, 0},
           {ToMigrate, 0},
           RestNodesWithPorts).

cluster_dead_node_message_reaper_test(Config) ->
    ok = ensure_cluster(Config),
    {_, [{Peer, Node, Port} | RestNodesWithPorts] = Nodes} = lists:keyfind(nodes, 1, Config),
    {_, RestNodes, _} = lists:unzip3(RestNodesWithPorts),
    Topic = "cluster/dead/message/reaper/topic",
    ToMigrate = 8,
    %% create ToMigrate unclean sessions
    _Sockets =
        [
            begin
                Connect = packet:gen_connect(
                    "connect-unclean-" ++ integer_to_list(I),
                    [
                        {clean_session, false},
                        {keepalive, 60}
                    ]
                ),
                Connack = packet:gen_connack(0),
                Subscribe = packet:gen_subscribe(123, Topic, 1),
                Suback = packet:gen_suback(123, 1),
                {ok, Socket} = packet:do_client_connect(Connect, Connack, [{port, Port}]),
                ok = gen_tcp:send(Socket, Subscribe),
                ok = packet:expect_packet(Socket, "suback", Suback),
                Socket
            end
         || I <- lists:seq(1, ToMigrate)
        ],
    _CleanSockets =
        [
            begin
                Connect = packet:gen_connect(
                    "connect-clean-" ++ integer_to_list(I),
                    [
                        {clean_session, true},
                        {keepalive, 60}
                    ]
                ),
                Connack = packet:gen_connack(0),
                Subscribe = packet:gen_subscribe(123, Topic, 1),
                Suback = packet:gen_suback(123, 1),
                {ok, Socket} = packet:do_client_connect(Connect, Connack, [{port, Port}]),
                ok = gen_tcp:send(Socket, Subscribe),
                ok = packet:expect_packet(Socket, "suback", Suback),
                Socket
            end
         || I <- lists:seq(1, ToMigrate)
        ],
    ok = vmq_cluster_test_utils:wait_until(
        fun() ->
            {ToMigrate * 2, 0, 0, 0, 0} == rpc:call(Node, vmq_queue_sup_sup, summary, [])
        end,
        60,
        500
    ),
    {_, RandomNode, RandomPort} = random_node(RestNodesWithPorts),
    Connect = packet:gen_connect(
                    "connect-clean-publish",
                    [
                        {clean_session, true},
                        {keepalive, 60}
                    ]
                ),
    Connack = packet:gen_connack(0),
    {ok, PubSocket} = packet:do_client_connect(Connect, Connack, [{port, RandomPort}]),
    Publish = packet:gen_publish(Topic, 1, <<"test-message">>, [{mid, 1}]),
    Puback = packet:gen_puback(1),
    %% Ungracefully stop node
    vmq_cluster_test_utils:stop_peer(Peer, Node),
    %% publish a message for every session
    ok = gen_tcp:send(PubSocket, Publish),
    ok = packet:expect_packet(PubSocket, "puback", Puback),
    %% ensure message is in redis queue by ensuring publisher node has not yet detected node failure
    true = length(Nodes) == length(rpc:call(RandomNode, vmq_cluster_mon, nodes, [])),
    %% check that the leave was propagated to the rest
    ok = wait_until_converged(
        RestNodesWithPorts,
        fun(N) ->
            lists:usort(rpc:call(N, vmq_cluster_mon, nodes, []))
        end,
        lists:usort(RestNodes)
    ),
    %% The disconnected sessions are migrated to the rest of the nodes 
    %% with the help of reapers
    %% As the clients don't reconnect (in this test), their sessions are offline
    %% Due to ungraceful shutdown, online messages were lost
    ok = wait_until_converged_fold(
           fun(N, {AccQ, AccM}) ->
                   {_,_,_,Queues, Messages} = rpc:call(N, vmq_queue_sup_sup, summary, []),
                   {AccQ + Queues, AccM + Messages}
           end,
           {0, 0},
           {ToMigrate, ToMigrate},
           RestNodesWithPorts).

shared_subs_prefer_local_policy_test_with_local_caching(Config) ->
    shared_subs_prefer_local_policy_test([{cache_shared_subscriptions_locally, true} | Config]).
shared_subs_prefer_local_policy_test(Config) ->
    ensure_cluster(Config),
    [LocalNode | OtherNodes] = _Nodes = nodes_(Config),
    set_shared_subs_policy(prefer_local, nodenames(Config)),
    set_shared_subs_local_caching(Config),

    LocalSubscriberSockets = connect_subscribers(<<"$share/share/sharedtopic">>, 5, [LocalNode]),
    RemoteSubscriberSockets = connect_subscribers(<<"$share/share/sharedtopic">>, 5, OtherNodes),

    %% publish to shared topic on local node
    {_, _, LocalPort} = LocalNode,
    Connect = packet:gen_connect(
        "ss-publisher",
        [{keepalive, 60}, {clean_session, true}]
    ),
    Connack = packet:gen_connack(0),
    {ok, Socket} = packet:do_client_connect(Connect, Connack, [{port, LocalPort}]),
    Payloads = publish_to_topic(Socket, <<"sharedtopic">>, 10),
    Disconnect = packet:gen_disconnect(),
    ok = gen_tcp:send(Socket, Disconnect),
    ok = gen_tcp:close(Socket),

    %% receive on subscriber sockets.
    spawn_receivers(LocalSubscriberSockets),
    receive_msgs(Payloads),
    receive_nothing(200),
    spawn_receivers(RemoteSubscriberSockets),
    receive_nothing(200),

    %% cleanup
    [ok = gen_tcp:close(S) || S <- LocalSubscriberSockets ++ RemoteSubscriberSockets],
    ok.

shared_subs_local_only_policy_test_with_local_caching(Config) ->
    shared_subs_local_only_policy_test([{cache_shared_subscriptions_locally, true} | Config]).
shared_subs_local_only_policy_test(Config) ->
    ensure_cluster(Config),
    [LocalNode | OtherNodes] = _Nodes = nodes_(Config),
    set_shared_subs_policy(local_only, nodenames(Config)),
    set_shared_subs_local_caching(Config),

    LocalSubscriberSockets = connect_subscribers(<<"$share/share/sharedtopic">>, 5, [LocalNode]),
    RemoteSubscriberSockets = connect_subscribers(<<"$share/share/sharedtopic">>, 5, OtherNodes),

    %% publish to shared topic on local node
    {_, _, LocalPort} = LocalNode,
    Connect = packet:gen_connect(
        "ss-publisher",
        [{keepalive, 60}, {clean_session, true}]
    ),
    Connack = packet:gen_connack(0),
    {ok, Socket} = packet:do_client_connect(Connect, Connack, [{port, LocalPort}]),
    Payloads = publish_to_topic(Socket, <<"sharedtopic">>, 10),

    %% receive on subscriber sockets.
    spawn_receivers(LocalSubscriberSockets),
    receive_msgs(Payloads),
    receive_nothing(200),
    spawn_receivers(RemoteSubscriberSockets),
    receive_nothing(200),

    %% disconnect all locals
    Disconnect = packet:gen_disconnect(),
    [
        begin
            ok = gen_tcp:send(S, Disconnect),
            ok = gen_tcp:close(S)
        end
     || S <- LocalSubscriberSockets
    ],

    _ = publish_to_topic(Socket, <<"sharedtopic">>, 11, 20),
    ok = gen_tcp:send(Socket, Disconnect),
    ok = gen_tcp:close(Socket),

    %% receive nothing as policy was local_only
    receive_nothing(200),

    %% cleanup
    [ok = gen_tcp:close(S) || S <- RemoteSubscriberSockets],
    ok.

shared_subs_random_policy_test_with_local_caching(Config) ->
    shared_subs_random_policy_test([{cache_shared_subscriptions_locally, true} | Config]).
shared_subs_random_policy_test(Config) ->
    ensure_cluster(Config),
    Nodes = nodes_(Config),

    set_shared_subs_policy(random, nodenames(Config)),
    set_shared_subs_local_caching(Config),

    SubscriberSockets = connect_subscribers(<<"$share/share/sharedtopic">>, 10, Nodes),

    %% publish to shared topic on random node
    {_, _, Port} = random_node(Nodes),
    Connect = packet:gen_connect(
        "ss-publisher",
        [{keepalive, 60}, {clean_session, true}]
    ),
    Connack = packet:gen_connack(0),
    {ok, Socket} = packet:do_client_connect(Connect, Connack, [{port, Port}]),
    Payloads = publish_to_topic(Socket, <<"sharedtopic">>, 10),
    Disconnect = packet:gen_disconnect(),
    ok = gen_tcp:send(Socket, Disconnect),
    ok = gen_tcp:close(Socket),

    %% receive on subscriber sockets.
    spawn_receivers(SubscriberSockets),
    receive_msgs(Payloads),
    receive_nothing(200),

    %% cleanup
    [ok = gen_tcp:close(S) || S <- SubscriberSockets],
    ok.

%% TODO: enable this after groups are honoured in shared subscriptions
shared_subs_random_policy_online_first_test_with_local_caching(Config) ->
    shared_subs_random_policy_online_first_test([{cache_shared_subscriptions_locally, true} | Config]).
shared_subs_random_policy_online_first_test(Config) ->
    ensure_cluster(Config),
    Nodes = nodes_(Config),
    set_shared_subs_policy(random, nodenames(Config)),
    set_shared_subs_local_caching(Config),

    [OnlineSubNode | RestNodes] = Nodes,
    create_offline_subscribers(<<"$share/share/sharedtopic">>, 10, RestNodes),
    SubscriberSocketsOnline = connect_subscribers(<<"$share/share/sharedtopic">>, 1, [OnlineSubNode]),

    %% publish to shared topic on random node
    {_, _, Port} = random_node(RestNodes),
    Connect = packet:gen_connect(
        "ss-publisher",
        [{keepalive, 60}, {clean_session, true}]
    ),
    Connack = packet:gen_connack(0),
    {ok, Socket} = packet:do_client_connect(Connect, Connack, [{port, Port}]),
    Payloads = publish_to_topic(Socket, <<"sharedtopic">>, 10),
    Disconnect = packet:gen_disconnect(),
    ok = gen_tcp:send(Socket, Disconnect),
    ok = gen_tcp:close(Socket),

    %% receive on subscriber sockets.
    spawn_receivers(SubscriberSocketsOnline),
    receive_msgs(Payloads),
    receive_nothing(200),

    %% cleanup
    [ok = gen_tcp:close(S) || S <- SubscriberSocketsOnline],
    ok.

shared_subs_random_policy_all_offline_test_with_local_caching(Config) ->
    shared_subs_random_policy_all_offline_test([{cache_shared_subscriptions_locally, true} | Config]).
shared_subs_random_policy_all_offline_test(Config) ->
    ensure_cluster(Config),
    Nodes = nodes_(Config),
    set_shared_subs_policy(random, nodenames(Config)),
    set_shared_subs_local_caching(Config),

    OfflineClients = create_offline_subscribers(<<"$share/share/sharedtopic">>, 10, Nodes),

    %% publish to shared topic on random node
    {_, _, Port} = random_node(Nodes),
    Connect = packet:gen_connect(
        "ss-publisher",
        [{keepalive, 60}, {clean_session, true}]
    ),
    Connack = packet:gen_connack(0),
    {ok, Socket} = packet:do_client_connect(Connect, Connack, [{port, Port}]),
    Payloads = publish_to_topic(Socket, <<"sharedtopic">>, 10),
    Disconnect = packet:gen_disconnect(),
    ok = gen_tcp:send(Socket, Disconnect),
    ok = gen_tcp:close(Socket),
    timer:sleep(100),

    SubscriberSocketsOnline = reconnect_clients(OfflineClients, Nodes),
    %% receive on subscriber sockets.
    spawn_receivers(SubscriberSocketsOnline),
    receive_msgs(Payloads),
    receive_nothing(200),

    %% cleanup
    [ok = gen_tcp:close(S) || S <- SubscriberSocketsOnline],
    ok.

routing_table_survives_node_restart(Config) ->
    %% Ensure that we subscribers can still receive publishes from a
    %% node that has been restarted. I.e., this ensures that the
    %% routing table of the restarted node is intact.
    ok = ensure_cluster(Config),
    {_, Nodes} = lists:keyfind(nodes, 1, Config),
    [
        {RestartNodePeer, RestartNodeName, RestartNodePort},
        {_, _, OtherNodePort}
        | _
    ] = Nodes,

    %% Connect and subscribe on a node with cs true
    Topic = <<"topic/sub">>,
    SharedTopic = <<"$share/group/sharedtopic">>,
    ClientId = "restart-node-test-subscriber",
    SubSocket = connect(OtherNodePort, ClientId, [{keepalive, 60}, {clean_session, true}]),
    subscribe(SubSocket, Topic, 1),
    subscribe(SubSocket, SharedTopic, 1),

    %% Restart the node.
    _ = vmq_cluster_test_utils:stop_peer(RestartNodePeer, RestartNodeName),
    {ok, _, Node} = vmq_cluster_test_utils:start_node(
        nodename(RestartNodeName),
        Config,
        routing_table_survives_node_restart
    ),

    {ok, _} = rpc:call(Node, vmq_server_cmd, listener_start, [RestartNodePort, []]),
    ok = rpc:call(Node, vmq_auth, register_hooks, []),

    %% Publish to the subscribed topics
    Connect = packet:gen_connect(
        "restart-node-test-publisher",
        [{keepalive, 60}, {clean_session, true}]
    ),
    Connack = packet:gen_connack(0),
    {ok, Socket} = packet:do_client_connect(Connect, Connack, [{port, RestartNodePort}]),
    Payloads = publish_to_topic(Socket, Topic, 1, 5),
    PayloadsShared = publish_to_topic(Socket, <<"sharedtopic">>, 6, 10),
    Disconnect = packet:gen_disconnect(),
    ok = gen_tcp:send(Socket, Disconnect),
    ok = gen_tcp:close(Socket),

    %% Make sure everything arrives successfully
    spawn_receivers([SubSocket]),
    receive_msgs(Payloads ++ PayloadsShared),
    receive_nothing(200).

cross_node_publish_subscribe(Config) ->
    %% Make sure all subscribers on a cross-node publish receive the
    %% published messages.
    ok = ensure_cluster(Config),
    {_, Nodes} = lists:keyfind(nodes, 1, Config),

    Topic = <<"cross-node-topic">>,

    %% 1. Connect two or more subscribers to node1.
    [LocalNode | OtherNodes] = Nodes = nodes_(Config),
    LocalSubscriberSockets = connect_subscribers(Topic, 5, [LocalNode]),

    %% 2. Connect and publish on another node.
    {_, _, OtherPort} = random_node(OtherNodes),
    Connect = packet:gen_connect(
        "publisher",
        [{keepalive, 60}, {clean_session, true}]
    ),
    Connack = packet:gen_connack(0),
    {ok, Socket} = packet:do_client_connect(Connect, Connack, [{port, OtherPort}]),
    Payloads = publish_to_topic(Socket, Topic, 10),
    Disconnect = packet:gen_disconnect(),
    ok = gen_tcp:send(Socket, Disconnect),
    ok = gen_tcp:close(Socket),

    %% 3. Check our subscribers received all messages.
    %% receive on subscriber sockets.
    spawn_receivers(LocalSubscriberSockets),

    %% the payloads will be received 5 times as all subscribers will
    %% get a copy.
    receive_msgs(
        Payloads ++
            Payloads ++
            Payloads ++
            Payloads ++
            Payloads
    ),
    receive_nothing(200).

shared_subs_random_policy_dead_node_message_reaper_test(Config) ->
    ok = ensure_cluster(Config),
    Nodes = nodenames(Config),

    set_shared_subs_policy(random, Nodes),

    Topic = <<"shared-subs-topic">>,
    SharedTopic = <<"$share/group/", Topic/binary>>,
    S1Connect = packet:gen_connect("shared-subscriber-1", [{clean_session, true}]),
    S2Connect = packet:gen_connect("shared-subscriber-2", [{clean_session, true}]),
    PConnect = packet:gen_connect("publisher", [{clean_session, true}]),
    Connack = packet:gen_connack(0),
    Subscribe = packet:gen_subscribe(123, SharedTopic, 1),
    Suback = packet:gen_suback(123, 1),
    
    {_, [{DPeer, DNode, DPort} | RestNodesWithPorts]} = lists:keyfind(nodes, 1, Config),
    {ok, S1Socket} = packet:do_client_connect(S1Connect, Connack, [{port, DPort}]),
    ok = gen_tcp:send(S1Socket, Subscribe),
    ok = packet:expect_packet(S1Socket, "suback", Suback),

    {_, RandomNode, RandomPort} = random_node(RestNodesWithPorts),
    {ok, S2Socket} = packet:do_client_connect(S2Connect, Connack, [{port, RandomPort}]),
    ok = gen_tcp:send(S2Socket, Subscribe),
    ok = packet:expect_packet(S2Socket, "suback", Suback),

    {ok, PubSocket} = packet:do_client_connect(PConnect, Connack, [{port, RandomPort}]),

    {ok, RC} = eredis:start_link([{host, "127.0.0.1"}, {database, 1}, {reconnect_sleep, no_reconnect}]),

    %% Ungracefully stop node
    vmq_cluster_test_utils:stop_peer(DPeer, DNode),
    
    %% publish messages
    Payloads = publish_to_topic(PubSocket, Topic, 100),

    %% Verify if messages are queued in the main queue of DeadNode
    Key = "mainQueue::" ++ atom_to_list(DNode),
    {ok, Size} = eredis:q(RC, ["LLEN", Key]),
    true = binary_to_integer(Size) > 0,
    
    %% Puback received means the published message got processed.
    %% Since messages were processed before detecting node failure, it means the messages 
    %% would be in main queue of dead node.
    true = length(Nodes) == length(rpc:call(RandomNode, vmq_cluster_mon, nodes, [])),

    timer:sleep(2000),

    %% Make sure all messages arrives successfully
    spawn_receivers([S2Socket]),
    receive_msgs(Payloads),
    receive_nothing(200).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% Internal
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
create_offline_subscribers(Topic, Number, Nodes) ->
    lists:foldr(
        fun(I, Acc) ->
            {_, _, Port} = random_node(Nodes),
            ClientId =
                "subscriber-" ++ integer_to_list(I) ++ "-node-" ++
                    integer_to_list(Port),
            Connect = packet:gen_connect(
                ClientId,
                [{keepalive, 60}, {clean_session, false}]
            ),
            Connack = packet:gen_connack(0),
            Subscribe = packet:gen_subscribe(1, [Topic], 1),
            Suback = packet:gen_suback(1, 1),
            %% TODO: make it connect to random node instead
            {ok, Socket} = packet:do_client_connect(Connect, Connack, [{port, Port}]),
            ok = gen_tcp:send(Socket, Subscribe),
            ok = packet:expect_packet(Socket, "suback", Suback),
            Disconnect = packet:gen_disconnect(),
            ok = gen_tcp:send(Socket, Disconnect),
            ok = gen_tcp:close(Socket),
            %% wait for the client to be offline
            timer:sleep(500),
            [ClientId | Acc]
        end,
        [],
        lists:seq(1, Number)
    ).

reconnect_clients(Clients, Nodes) ->
    lists:foldl(
        fun(ClientId, Acc) ->
            {_, _, Port} = random_node(Nodes),
            Connect = packet:gen_connect(
                ClientId,
                [{keepalive, 60}, {clean_session, false}]
            ),
            Connack = packet:gen_connack(1, 0),
            {ok, Socket} = packet:do_client_connect(Connect, Connack, [{port, Port}]),
            [Socket | Acc]
        end,
        [],
        Clients
    ).

connect_subscribers(Topic, Number, Nodes) ->
    [
        begin
            {_, _, Port} = random_node(Nodes),
            Connect = packet:gen_connect(
                "subscriber-" ++ integer_to_list(I) ++ "-node-" ++
                    integer_to_list(Port),
                [{keepalive, 60}, {clean_session, true}]
            ),
            Connack = packet:gen_connack(0),
            Subscribe = packet:gen_subscribe(1, [Topic], 1),
            Suback = packet:gen_suback(1, 1),
            %% TODO: make it connect to random node instead
            {ok, Socket} = packet:do_client_connect(Connect, Connack, [{port, Port}]),
            ok = gen_tcp:send(Socket, Subscribe),
            ok = packet:expect_packet(Socket, "suback", Suback),
            Socket
        end
     || I <- lists:seq(1, Number)
    ].

publish_to_topic(Socket, Topic, Number) when Number > 1 ->
    publish_to_topic(Socket, Topic, 1, Number).

publish_to_topic(Socket, Topic, Begin, End) when Begin < End ->
    [
        begin
            Payload = vmq_test_utils:rand_bytes(5),
            Publish = packet:gen_publish(Topic, 1, Payload, [{mid, I}]),
            Puback = packet:gen_puback(I),
            ok = gen_tcp:send(Socket, Publish),
            ok = packet:expect_packet(Socket, "puback", Puback),
            Payload
        end
     || I <- lists:seq(Begin, End)
    ].

set_shared_subs_policy(Policy, Nodes) ->
    lists:foreach(
        fun(N) ->
            {ok, _} = rpc:call(N, vmq_server_cmd, set_config, [shared_subscription_policy, Policy])
        end,
        Nodes
    ).

set_shared_subs_local_caching(Config) ->
    Value = case lists:keyfind(cache_shared_subscriptions_locally, 1, Config) of
        {_, V} -> V;
        false -> false
    end,
    Nodes = nodenames(Config),
    lists:foreach(
        fun(N) ->
            {ok, _} = rpc:call(N, vmq_server_cmd, set_config, [cache_shared_subscriptions_locally, Value])
        end,
        Nodes
    ).

nodenames(Config) ->
    {_, NodeNames, _} = lists:unzip3(nodes_(Config)),
    NodeNames.

nodes_(Config) ->
    {_, Nodes} = lists:keyfind(nodes, 1, Config),
    Nodes.

spawn_receivers(ReceiverSockets) ->
    Master = self(),
    lists:map(
        fun(S) ->
            spawn_link(fun() -> recv_and_forward_msg(S, Master, <<>>) end)
        end,
        ReceiverSockets
    ).

receive_msgs(Payloads) ->
    receive_msgs(Payloads, 5000).

receive_msgs([], _Wait) ->
    ok;
receive_msgs(Payloads, Wait) ->
    receive
        #mqtt_publish{payload = Payload} ->
            true = lists:member(Payload, Payloads),
            receive_msgs(Payloads -- [Payload])
    after Wait -> ST = ?stacktrace, throw({wait_for_messages_timeout, Payloads, ST})
    end.

receive_nothing(Wait) ->
    receive
        X -> ST = ?stacktrace, throw({received_unexpected_msgs, X, ST})
    after
        Wait -> ok
    end.

recv_and_forward_msg(Socket, Dest, Rest) ->
    case recv_all(Socket, Rest) of
        {ok, Frames, Rest} ->
            lists:foreach(
                fun(#mqtt_publish{message_id = MsgId} = Msg) ->
                    ok = gen_tcp:send(Socket, packet:gen_puback(MsgId)),
                    Dest ! Msg
                end,
                Frames
            ),
            recv_and_forward_msg(Socket, Dest, Rest);
        {error, _Reason} ->
            ok
    end.

publish(Nodes, NrOfProcesses, NrOfMsgsPerProcess) ->
    publish(self(), Nodes, NrOfProcesses, NrOfMsgsPerProcess, []).

publish(_, _, 0, _, Pids) ->
    Pids;
publish(Self, [Node | Rest] = Nodes, NrOfProcesses, NrOfMsgsPerProcess, Pids) ->
    Pid = spawn_link(fun() -> publish_(Self, {Node, Nodes}, NrOfMsgsPerProcess) end),
    publish(Self, Rest ++ [Node], NrOfProcesses - 1, NrOfMsgsPerProcess, [Pid | Pids]).

publish_(Self, Node, NrOfMsgsPerProcess) ->
    publish__(Self, Node, NrOfMsgsPerProcess).
publish__(Self, _, 0) ->
    Self ! done;
publish__(Self, {{_, _, Port}, Nodes} = Conf, NrOfMsgsPerProcess) ->
    Connect = packet:gen_connect("connect-multiple", [{keepalive, 10}]),
    Connack = packet:gen_connack(0),
    case packet:do_client_connect(Connect, Connack, [{port, Port}]) of
        {ok, Socket} ->
            check_unique_client("connect-multiple", Nodes),
            gen_tcp:close(Socket),
            timer:sleep(rand:uniform(100)),
            publish__(Self, Conf, NrOfMsgsPerProcess - 1);
        {error, closed} ->
            %% this happens if at the same time the same client id
            %% connects to the cluster
            timer:sleep(rand:uniform(100)),
            publish__(Self, Conf, NrOfMsgsPerProcess)
    end.

publish_random(Nodes, N, Topic) ->
    publish_random(Nodes, N, Topic, []).

publish_random(_, 0, _, Acc) ->
    Acc;
publish_random(Nodes, N, Topic, Acc) ->
    Connect = packet:gen_connect("connect-unclean-pub", [
        {clean_session, true},
        {keepalive, 10}
    ]),
    Connack = packet:gen_connack(0),
    Payload = vmq_test_utils:rand_bytes(rand:uniform(50)),
    Publish = packet:gen_publish(Topic, 1, Payload, [{mid, N}]),
    Puback = packet:gen_puback(N),
    Disconnect = packet:gen_disconnect(),
    {ok, Socket} = packet:do_client_connect(Connect, Connack, opts(Nodes)),
    ok = gen_tcp:send(Socket, Publish),
    ok = packet:expect_packet(Socket, "puback", Puback),
    ok = gen_tcp:send(Socket, Disconnect),
    gen_tcp:close(Socket),
    publish_random(Nodes, N - 1, Topic, [Payload | Acc]).

receive_publishes(_, _, []) ->
    ok;
receive_publishes([{_, _, Port} = N | Nodes], Topic, Payloads) ->
    Connect = packet:gen_connect("connect-unclean", [
        {clean_session, false},
        {keepalive, 10}
    ]),
    Connack = packet:gen_connack(true, 0),
    Opts = [{port, Port}],
    {ok, Socket} = packet:do_client_connect(Connect, Connack, Opts),
    case recv(Socket, <<>>) of
        {ok, #mqtt_publish{message_id = MsgId, payload = Payload}} ->
            ok = gen_tcp:send(Socket, packet:gen_puback(MsgId)),
            receive_publishes(Nodes ++ [N], Topic, Payloads -- [Payload]);
        {error, _} ->
            receive_publishes(Nodes ++ [N], Topic, Payloads)
    end.

recv(Socket, Buf) ->
    case recv_all(Socket, Buf) of
        {ok, [], Rest} ->
            recv_all(Socket, Rest);
        {ok, [Frame | _], _Rest} ->
            {ok, Frame};
        E ->
            E
    end.

recv_all(Socket, Buf) ->
    case gen_tcp:recv(Socket, 0) of
        {ok, Data} ->
            NewData = <<Buf/binary, Data/binary>>,
            parse_all(NewData);
        {error, Reason} ->
            {error, Reason}
    end.

parse_all(Data) ->
    parse_all(Data, []).

parse_all(Data, Frames) ->
    case vmq_parser:parse(Data) of
        more ->
            {ok, lists:reverse(Frames), Data};
        {error, _Rest} ->
            {error, parse_error};
        error ->
            {error, parse_error};
        {Frame, Rest} ->
            parse_all(Rest, [Frame | Frames])
    end.

connect(Port, ClientId, Opts) ->
    Connect = packet:gen_connect(ClientId, Opts),
    Connack = packet:gen_connack(0),
    {ok, Socket} = packet:do_client_connect(Connect, Connack, [{port, Port}]),
    Socket.

subscribe(Socket, Topic, QoS) ->
    Subscribe = packet:gen_subscribe(1, [Topic], QoS),
    Suback = packet:gen_suback(1, QoS),
    ok = gen_tcp:send(Socket, Subscribe),
    ok = packet:expect_packet(Socket, "suback", Suback).

ensure_cluster(Config) ->
    vmq_cluster_test_utils:ensure_cluster(Config).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% Hooks
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
hook_uname_password_success(_, _, _, _, _) -> {ok, [{max_inflight_messages, 1}]}.
hook_auth_on_publish(_, _, _, _, _, _) -> ok.
hook_auth_on_subscribe(_, _, _) -> ok.

random_node(Nodes) ->
    lists:nth(rand:uniform(length(Nodes)), Nodes).

opts(Nodes) ->
    {_, _, Port} = lists:nth(rand:uniform(length(Nodes)), Nodes),
    [{port, Port}].

check_unique_client(ClientId, Nodes) ->
    Res =
        lists:foldl(
            fun({_Peer, Node, _Port}, Acc) ->
                case rpc:call(Node, vmq_reg, get_session_pids, [ClientId]) of
                    {ok, [Pid]} ->
                        [{Node, Pid} | Acc];
                    {error, not_found} ->
                        Acc
                end
            end,
            [],
            Nodes
        ),
    L = length(Res),
    case L > 1 of
        true ->
            io:format(user, "multiple registered ~p~n", [Res]);
        false ->
            ok
    end,
    length(Res) =< 1.

receive_times(Msg, 0) ->
    Msg;
receive_times(Msg, N) ->
    receive
        Msg ->
            receive_times(Msg, N - 1)
    end.

%% Get the nodename part of nodename@host. This is a hack due to the
%% fact that PRE erlang 20 ct_slave:start/2, the hostname would be
%% unconditionally appended to the nodename forming invalid names such
%% as nodename@host@host.
nodename(Node) when is_atom(Node) ->
    list_to_atom(lists:takewhile(fun(C) -> C =/= $@ end, atom_to_list(Node))).
