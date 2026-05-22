%% Copyright 2018 Erlio GmbH Basel Switzerland (http://erl.io)
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%
-module(vmq_cluster_mon).

-behaviour(gen_server).

%% API functions
-export([
    start_link/0,
    nodes/0,
    status/0,
    is_node_alive/1
]).

%% gen_server callbacks
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-include("vmq_server.hrl").

-record(state, {
    fall = 3,
    timer = undefined,
    recheck_interval = 500,
    last_recheck_ts = undefined
}).
-define(VMQ_CLUSTER_STATUS, vmq_status).

%%%===================================================================
%%% API functions
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec nodes() -> [any()].
nodes() ->
    [
        Node
     || [{Node, true, _}] <-
            ets:match(?VMQ_CLUSTER_STATUS, '$1')
    ].

-spec status() -> [any()].
status() ->
    [
        {Node, Ready}
     || [{Node, Ready, _}] <-
            ets:match(?VMQ_CLUSTER_STATUS, '$1')
    ].

-spec is_node_alive(atom()) -> boolean().
is_node_alive(Node) ->
    try
        ets:lookup_element(?VMQ_CLUSTER_STATUS, Node, 2)
    catch
        _:_ ->
            false
    end.

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
init([]) ->
    ets:new(?VMQ_CLUSTER_STATUS, [{read_concurrency, true}, public, named_table]),

    Fall = application:get_env(vmq_server, cluster_node_liveness_fall, 3),
    RecheckInterval = application:get_env(vmq_server, cluster_node_liveness_check_interval, 500),

    ReadyResult =
        case vmq_config:get_env(direct_message_passing, false) of
            true ->
                {ok, <<"0">>};
            false ->
                vmq_state_store_backend:ensure_no_local_client()
        end,

    case ReadyResult of
        {ok, <<"0">>} ->
            Tref = erlang:send_after(0, self(), recheck),
            {ok, #state{
                fall = Fall,
                timer = Tref,
                recheck_interval = RecheckInterval
            }};
        {ok, _} ->
            {stop, reaping_in_progress};
        {error, Reason} ->
            {stop, Reason}
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @spec handle_call(Request, From, State) ->
%%                                   {reply, Reply, State} |
%%                                   {reply, Reply, State, Timeout} |
%%                                   {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, Reply, State} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------

handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%                                  {noreply, State, Timeout} |
%%                                  {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_info(recheck, State) ->
    Now = erlang:monotonic_time(microsecond),
    %% Heartbeat-gap metric: time since the previous recheck started. The
    %% recheck loop is what writes this node's own Redis heartbeat (the
    %% ZADD inside get_live_nodes). If this gap exceeds the 3s live-set
    %% expiry, the node will be falsely reaped by its peers.
    case State#state.last_recheck_ts of
        undefined ->
            ok;
        Prev ->
            Gap = Now - Prev,
            vmq_metrics:pretimed_measurement({?MODULE, recheck_gap}, Gap),
            case Gap > 3000000 of
                true ->
                    lager:warning(
                        "[liveness] recheck gap ~pms -- heartbeat lapsed, peers may reap this node",
                        [Gap div 1000]
                    );
                false ->
                    ok
            end
    end,
    %% Time the heartbeat write (get_live_nodes) and the peer health-check
    %% loop (update_cluster_status) separately, so we can see which one stalls.
    GlnStart = erlang:monotonic_time(microsecond),
    GlnResult = vmq_state_store_backend:get_live_nodes(),
    GlnDur = erlang:monotonic_time(microsecond) - GlnStart,
    vmq_metrics:pretimed_measurement({?MODULE, get_live_nodes_duration}, GlnDur),
    case GlnDur > 1000000 of
        true ->
            lager:warning("[liveness] get_live_nodes took ~pms", [GlnDur div 1000]);
        false ->
            ok
    end,
    case GlnResult of
        {ok, LiveNodes} when is_list(LiveNodes) ->
            UcsStart = erlang:monotonic_time(microsecond),
            LiveNodesAtom = update_cluster_status(LiveNodes, []),
            UcsDur = erlang:monotonic_time(microsecond) - UcsStart,
            vmq_metrics:pretimed_measurement({?MODULE, update_cluster_status_duration}, UcsDur),
            case UcsDur > 1000000 of
                true ->
                    lager:warning("[liveness] update_cluster_status took ~pms", [UcsDur div 1000]);
                false ->
                    ok
            end,
            filter_dead_nodes(LiveNodesAtom, State#state.fall);
        Res ->
            lager:error("[liveness] get_live_nodes failed (heartbeat not written): ~p", [Res])
    end,
    NewTRef = erlang:send_after(
        State#state.recheck_interval,
        self(),
        recheck
    ),
    {noreply, State#state{
        timer = NewTRef,
        last_recheck_ts = Now
    }};
handle_info(Info, State) ->
    lager:warning("received unexpected message ~p~n", [Info]),
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
update_cluster_status([], Acc) ->
    Acc;
update_cluster_status([BNode | Rest], Acc) ->
    Node = binary_to_atom(BNode),
    %% Time each blocking call against a peer separately, so we can tell which
    %% one stalls the recheck loop (and for which peer). Both rpc:call and
    %% node_status (via get_cluster_node's restart-retry) are unbounded.
    %%
    %%
    %% cluster_node_liveness_rpc_timeout default 1/2 TBD
    RpcTimeout = application:get_env(vmq_server, cluster_node_liveness_rpc_timeout, 1000),
    IsReady = timed_step(rpc_call, Node, fun() ->
        case rpc:call(Node, erlang, whereis, [vmq_server_sup], RpcTimeout) of
            Pid when is_pid(Pid) -> true;
            _ -> false
        end
    end),
    vmq_state_store_backend:del_reaper(Node),
    ets:insert(?VMQ_CLUSTER_STATUS, {Node, true, 0}),
    timed_step(ensure_cluster_node, Node, fun() ->
        vmq_cluster_node_sup:ensure_cluster_node(Node)
    end),
    Status = timed_step(node_status, Node, fun() ->
        vmq_cluster_node_sup:node_status(Node)
    end),
    IsReady1 = IsReady andalso lists:member(Status, [up, init]),
    ets:insert(?VMQ_CLUSTER_STATUS, {Node, IsReady1, 0}),
    update_cluster_status(Rest, [Node | Acc]).

%% Run Fun, record its duration in a per-step histogram, and warn (with the
%% peer node) if it blocks for more than 1s -- pinpoints which call in the
%% liveness loop stalls and delays the next heartbeat write.
timed_step(Step, Node, Fun) ->
    Start = erlang:monotonic_time(microsecond),
    Result = Fun(),
    Dur = erlang:monotonic_time(microsecond) - Start,
    vmq_metrics:pretimed_measurement({?MODULE, Step}, Dur),
    case Dur > 1000000 of
        true ->
            lager:warning("[liveness] ~p for peer ~p took ~pms", [Step, Node, Dur div 1000]);
        false ->
            ok
    end,
    Result.

filter_dead_nodes(Nodes, Fall) ->
    ets:foldl(
        fun({Node, _IsReady, FailedAttempts}, _) ->
            case lists:member(Node, Nodes) of
                true ->
                    ok;
                false when FailedAttempts > Fall ->
                    %% Node is not part of the cluster anymore
                    lager:warning("trigger reaper for node ~p", [Node]),
                    vmq_state_store_backend:ensure_reaper(Node),
                    ets:delete(?VMQ_CLUSTER_STATUS, Node);
                false ->
                    ets:update_element(?VMQ_CLUSTER_STATUS, Node, [
                        {2, false}, {3, FailedAttempts + 1}
                    ])
            end
        end,
        ok,
        ?VMQ_CLUSTER_STATUS
    ),
    ok.
