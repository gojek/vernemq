%% -------------------------------------------------------------------
%%
%% Copyright (c) 2015 Helium Systems, Inc.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

-module(vmq_cluster_test_utils).

-export([get_cluster_members/1, pmap/2, wait_until/3, wait_until_left/2,
         wait_until_joined/1, wait_until_joined/2, wait_until_offline/1, wait_until_disconnected/2,
         wait_until_connected/2, start_node/3, partition_cluster/2, heal_cluster/2,
         ensure_cluster/1,start_peer/2,
         stop_peer/2,init_distribution/1,random_node_with_port/1]).

-include_lib("eunit/include/eunit.hrl").

get_cluster_members(Node) ->
    rpc:call(Node, vmq_cluster_mon, nodes, []).

pmap(F, L) ->
    Parent = self(),
    lists:foldl(fun(X, N) ->
                   spawn_link(fun() -> Parent ! {pmap, N, F(X)} end),
                   N + 1
                end,
                0,
                L),
    L2 = [receive
              {pmap, N, R} ->
                  {N, R}
          end
          || _ <- L],
    {_, L3} =
        lists:unzip(
            lists:keysort(1, L2)),
    L3.

wait_until(Fun, Retry, Delay) when Retry > 0 ->
    Res = Fun(),
    case Res of
        true ->
            ok;
        _ when Retry == 1 ->
            {fail, Res};
        _ ->
            timer:sleep(Delay),
            wait_until(Fun, Retry - 1, Delay)
    end.

wait_until_left(Nodes, LeavingNode) ->
    wait_until(fun() ->
                  lists:all(fun(X) -> X == true end,
                            pmap(fun(Node) ->
                                    not lists:member(LeavingNode, get_cluster_members(Node))
                                 end,
                                 Nodes))
               end,
               60 * 2,
               500).

wait_until_joined(Nodes) ->
    wait_until_joined(Nodes, Nodes).

wait_until_joined(Nodes, ExpectedCluster) ->
    wait_until(fun() ->
                  lists:all(fun(X) -> X == true end,
                            pmap(fun(Node) ->
                                    lists:sort(ExpectedCluster)
                                    == lists:sort(get_cluster_members(Node))
                                 end,
                                 Nodes))
               end,
               60 * 2,
               500).

wait_until_offline(Node) ->
    wait_until(fun() -> pang == net_adm:ping(Node) end, 60 * 2, 500).

wait_until_disconnected(Node1, Node2) ->
    wait_until(fun() -> pang == rpc:call(Node1, net_adm, ping, [Node2]) end, 60 * 2, 500).

wait_until_connected(Node1, Node2) ->
    wait_until(fun() -> pong == rpc:call(Node1, net_adm, ping, [Node2]) end, 60 * 2, 500).

start_node(Name, _Config, Case) ->
    ct:pal("Start Node ~p for Case ~p~n", [Name, Case]),
    CodePath = lists:filter(fun filelib:is_dir/1, code:get_path()),
    %% have the slave nodes monitor the runner node, so they can't outlive it
    NodeConfig = #{name => Name, args => "-smp"},  %% peer module format
    VmqServerPrivDir = code:priv_dir(vmq_server),
    ct:log("Starting node ~p with Opts = ~p", [Name, NodeConfig]),
    case start_peer(Name, CodePath) of
        {ok, Peer, Node} ->
            %true = rpc:block_call(Node, code, set_path, [CodePath]),
            VmqServerPrivDir = code:priv_dir(vmq_server),
            EnhancedAuthPrivDir = code:priv_dir(vmq_enhanced_auth),
            {ok, NodeWorkingDir} = rpc:call(Node, file, get_cwd, []),
            NodeDir = filename:join([NodeWorkingDir, Node, Case]),
            ok = rpc:call(Node, application, load, [vmq_server]),
            ok = rpc:call(Node, application, load, [vmq_plugin]),
            ok = rpc:call(Node, application, load, [vmq_swc]),
            ok = rpc:call(Node, application, load, [vmq_enhanced_auth]),
            ok = rpc:call(Node, application, set_env, [eredis, host, "127.0.0.1"]),
            ok = rpc:call(Node, application, set_env, [eredis, port, 6379]),
            {ok, RedisClient} = rpc:call(Node, eredis, start_link, [[{host, "127.0.0.1"}, {port, 6379}]]),
            rpc:call(Node, eredis, q, [RedisClient, ["PING"]]),
            ok = rpc:call(Node, application, set_env, [vmq_server, metadata_impl, vmq_swc]),
            ok = rpc:call(Node, application, set_env, [vmq_server, max_drain_time, 5000]),
            ok = rpc:call(Node, application, set_env, [vmq_server, max_msgs_per_drain_step, 40]),
            ok = rpc:call(Node, application, set_env, [vmq_server, mqtt_connect_timeout, 12000]),
            ok = rpc:call(Node, application, set_env, [vmq_server, coordinate_registrations, true]),
            ok = rpc:call(Node, application, set_env, [vmq_server, allow_register_during_netsplit, true]),
            ok = rpc:call(Node, application, set_env, [vmq_server, allow_register_during_netsplit, true]),
            ok =
                rpc:call(Node,
                         application,
                         set_env,
                         [vmq_server, default_reg_view, vmq_reg_redis_trie]),
            ok =
                rpc:call(Node,
                         application,
                         set_env,
                         [vmq_server, systree_reg_view, vmq_reg_redis_trie]),
            ok =
                rpc:call(Node,
                         application,
                         set_env,
                         [vmq_server, redis_sentinel_endpoints, "[{\"127.0.0.1\", 26379}]"]),
            ok =
                rpc:call(Node,
                         application,
                         set_env,
                         [vmq_server, redis_lua_dir, VmqServerPrivDir ++ "/lua_scripts"]),
            ok = rpc:call(Node, application, set_env, [vmq_swc,
                                                       data_dir,
                                                       NodeDir]),
            
            ok = rpc:call(Node, application, set_env, [vmq_server, 
                          complex_trie_file, 
                          filename:join([VmqServerPrivDir, "vmq.trie"])]),                                           
            ok = rpc:call(Node, application, set_env, [vmq_swc,
                                                       metadata_root,
                                                       NodeDir ++ "/meta/"]),
            ok = rpc:call(Node, application, set_env, [vmq_server,
                                                       listeners,
                                                       [{vmq, [{{{127,0,0,1},
                                                                 random_port(Node)},
                                                                []}]}
                                                       ]]),
            ok = rpc:call(Node, application, load, [lager]),
            ok = rpc:call(Node, application, set_env, [lager, log_root, NodeDir]),
            ok = rpc:call(Node, application, set_env, [lager, log_level, debug]),
            ok = rpc:call(Node, application, set_env, [vmq_plugin, wait_for_proc, vmq_server_sup]),
            ok = rpc:call(Node, application, set_env, [vmq_plugin,
                                                       plugin_dir,
                                                       NodeDir]),
            ok = rpc:call(Node, application, set_env, [vmq_enhanced_auth,
                                                       acl_file,
                                                       filename:join([EnhancedAuthPrivDir, "default.acl"])]),
            ok =
                rpc:call(Node,
                         application,
                         set_env,
                         [vmq_plugin, default_schema_dir, [VmqServerPrivDir]]),
            {ok, _} = rpc:call(Node, application, ensure_all_started, [vmq_server]),
            {ok, _} = rpc:call(Node, application, ensure_all_started, [vmq_swc]),
            % {ok, _} = rpc:call(Node, application, ensure_all_started, [vmq_enhanced_auth]),
            ok = wait_until(
                fun() ->
                    case rpc:call(Node, vmq_cluster_mon, nodes, []) of
                        {error, no_matching_hook} ->
                            lager:error("No hook matched for cluster_members on node ~p", [Node]),
                            false;
                        Members when is_list(Members) ->
                            ct:pal("Current cluster members on node ~p: ~p", [Node, Members]),
                            ct:pal("Checking if vmq_server_sup process is running on node ~p", [Node]),
                            case rpc:call(Node, erlang, whereis, [vmq_server_sup]) of
                                undefined ->
                                    ct:pal("vmq_server_sup process is not running on node ~p", [Node]),
                                    false;
                                P when is_pid(P) ->
                                    ct:pal("vmq_server_sup process is running on node ~p with PID: ~p", [Node, P]),
                                    true
                            end;
                        Other ->
                            ct:pal("Unexpected result from cluster_members hook on node ~p: ~p", [Node, Other]),
                            false
                    end
                end,
                60,  % Timeout in seconds
                500  % Retry interval in milliseconds
            ),
            {ok, Peer, Node};
            Other ->
                ct:pal("wait_until/3 timed out or failed. Result: ~p", [Other]),
                Other
    end.

-if(?OTP_RELEASE >= 25).

start_peer(NodeName, CodePath) ->
    Opts =
        #{name => NodeName,
          wait_boot => infinity,
          %% Prevent overlapping partitions - See:
          %% https://www.erlang.org/doc/man/global.html#prevent_overlapping_partitions
          args => ["-kernel", "prevent_overlapping_partitions", "false", "-pz" | CodePath]},
    ct:log("Starting node ~p with Opts = ~p", [NodeName, Opts]),
    {ok, Peer, Node} = peer:start(Opts),
    {ok, Peer, Node}.

stop_peer(Peer, _Node) ->
    %% peer:stop/1 is not idempotent
    try
        %% Close Redis client connections
        case rpc:call(_Node, erlang, whereis, [eredis]) of
            undefined -> 
                ok;
            RedisPid when is_pid(RedisPid) ->
                ct:pal("Stopping Redis client on node ~p", [_Node]),
                rpc:call(_Node, eredis, stop, [])
        end,

        %% Stop the peer node
        peer:stop(Peer)
    catch
        exit:_:_Stacktrace ->
            ok
    end.

- else .

start_peer(NodeName, CodePath) ->
    PathFlag =
        "-pz "
        ++ lists:concat(
               lists:join(" ", CodePath)),
    %% smp for the eleveldb god
    Opts =
        [{monitor_master, true},
         {boot_timeout, 30},
         {init_timeout, 30},
         {startup_timeout, 30},
         {erl_flags, PathFlag},
         {startup_functions, [{code, add_pathz, [CodePath]}]}],
    ct:log("Starting node ~p with Opts = ~p", [NodeName, Opts]),
    case ct_slave:start(NodeName, Opts) of
        {ok, Node} ->
            {ok, Node, Node};
        {error, already_started, Node} ->
            ct:pal("Error starting node ~w, reason already_started, will retry", [Node]),
            ct_slave:stop(NodeName),
            wait_until_offline(Node),
            start_peer(NodeName, CodePath);
        {error, started_not_connected, Node} ->
            ct_slave:stop(NodeName),
            wait_until_offline(Node),
            start_peer(NodeName, CodePath);
        Other ->
            Other
    end.

stop_peer(Node, _) ->
    try
        %% Close Redis client connections
        case rpc:call(Node, erlang, whereis, [eredis]) of
            undefined -> 
                ok;
            RedisPid when is_pid(RedisPid) ->
                ct:pal("Stopping Redis client on node ~p", [Node]),
                rpc:call(Node, eredis, stop, [])
        end
    catch
        exit:_:_Stacktrace ->
            ok
    end,

    %% Stop the node
    ct_slave:stop(Node),
    ok.

-endif.

init_distribution(Config) ->
    {ok, Hostname} = inet:gethostname(),
    case erlang:is_alive() of
        false ->
            %% verify epmd running (otherwise next call fails)
            erl_epmd:names() =:= {error, address}
            andalso begin
                        [] = os:cmd("epmd -daemon"),
                        timer:sleep(500)
                    end,
            %% verify that epmd indeed started
            {ok, _} = erl_epmd:names(),
            %% start a random node name
            NodeName =
                list_to_atom("runner-"
                             ++ integer_to_list(erlang:system_time(nanosecond))
                             ++ "@"
                             ++ Hostname),
            {ok, Pid} = net_kernel:start([NodeName, shortnames]),
            [{distribution, Pid} | Config];
        true ->
            Config
    end.

partition_cluster(ANodes, BNodes) ->
    pmap(fun({Node1, Node2}) ->
            true = rpc:call(Node1, erlang, set_cookie, [Node2, canttouchthis]),
            true = rpc:call(Node1, erlang, disconnect_node, [Node2]),
            ok = wait_until_disconnected(Node1, Node2)
         end,
         [{Node1, Node2} || Node1 <- ANodes, Node2 <- BNodes]),
    ok.

heal_cluster(ANodes, BNodes) ->
    GoodCookie = erlang:get_cookie(),
    pmap(fun({Node1, Node2}) ->
            true = rpc:call(Node1, erlang, set_cookie, [Node2, GoodCookie]),
            ok = wait_until_connected(Node1, Node2)
         end,
         [{Node1, Node2} || Node1 <- ANodes, Node2 <- BNodes]),
    ok.

    
ensure_cluster(Config) ->
    [{_, Node1, _}|OtherNodes] = Nodes = proplists:get_value(nodes, Config),
    lager:info("Node1 ~p and other nodes ~p", [Node1, OtherNodes]),
    % [begin
    %      {ok, _} = rpc:call(Node, vmq_server_cmd, node_join, [Node1])
    %  end || {_Peer, Node, _} <- OtherNodes],
    {_, NodeNames, _} = lists:unzip3(Nodes),
    Expected = lists:sort(NodeNames),
    ok = vmq_cluster_test_utils:wait_until_joined(NodeNames, Expected),
    [?assertEqual({Node, Expected}, {Node,
                                     lists:sort(vmq_cluster_test_utils:get_cluster_members(Node))})
     || Node <- NodeNames],
    ok.

    random_node_with_port(Case) ->
        Name =
            list_to_atom(atom_to_list(Case)
                         ++ "-"
                         ++ integer_to_list(erlang:system_time(second))
                         ++ "-"
                         ++ integer_to_list(erlang:unique_integer([positive]))),
        Port = vmq_test_utils:get_free_port(),
        {Name, Port}.

        random_port(Node) ->
            10000 + (erlang:phash2(Node) rem 10000).