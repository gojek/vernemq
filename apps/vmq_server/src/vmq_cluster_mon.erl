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
    is_node_alive/1,
    prepare_shutdown/0
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

-record(state, {
    fall = 3,
    timer = undefined,
    recheck_interval = 500,
    shutting_down = false
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

-spec prepare_shutdown() -> ok.
prepare_shutdown() ->
    gen_server:call(?MODULE, prepare_shutdown, 5000).

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

    case vmq_state_store_backend:ensure_no_local_client() of
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
handle_call(prepare_shutdown, _From, #state{timer = Tref} = State) ->
    _ = (catch erlang:cancel_timer(Tref)),
    Res = vmq_state_store_backend:deregister_node(),
    lager:info("cluster_mon preparing for shutdown, node deregister result: ~p", [Res]),
    {reply, ok, State#state{shutting_down = true, timer = undefined}};
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
handle_info(recheck, #state{shutting_down = true} = State) ->
    {noreply, State};
handle_info(recheck, State) ->
    case vmq_state_store_backend:get_live_nodes() of
        {ok, LiveNodes} when is_list(LiveNodes) ->
            LiveNodesAtom = update_cluster_status(LiveNodes, []),
            filter_dead_nodes(LiveNodesAtom, State#state.fall);
        Res ->
            lager:error("~p", [Res])
    end,
    NewTRef = erlang:send_after(
        State#state.recheck_interval,
        self(),
        recheck
    ),
    {noreply, State#state{
        timer = NewTRef
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
    vmq_state_store_backend:del_reaper(Node),
    vmq_cluster_node_sup:ensure_cluster_node(Node),
    ets:insert(?VMQ_CLUSTER_STATUS, {Node, true, 0}),
    update_cluster_status(Rest, [Node | Acc]).

filter_dead_nodes(Nodes, Fall) ->
    ets:foldl(
        fun({Node, _IsReady, FailedAttempts}, _) ->
            case lists:member(Node, Nodes) of
                true ->
                    ok;
                false when FailedAttempts > Fall ->
                    %% Node is not part of the cluster anymore
                    _ = vmq_cluster_node_sup:del_cluster_node(Node),
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
