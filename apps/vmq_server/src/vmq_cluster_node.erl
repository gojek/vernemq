-module(vmq_cluster_node).

%% API
-export([
    start_link/1,
    publish/2,
    enqueue/4,
    connect_params/1,
    status/1
]).

%% gen_server callbacks
-export([
    init/1,
    loop/1
]).

-export([system_continue/3]).
-export([system_terminate/4]).
-export([system_code_change/4]).

-record(state, {
    parent,
    node,
    socket,
    transport,
    reachable = false,
    pending = [],
    max_queue_size,
    reconnect_tref,
    async_connect_pid,
    bytes_dropped = {os:timestamp(), 0},
    bytes_send = {os:timestamp(), 0}
}).

-define(RECONNECT, 1000).

%%%===================================================================
%%% API
%%%===================================================================

-spec start_link(node()) -> {ok, pid()} | {error, term()}.
start_link(RemoteNode) ->
    proc_lib:start_link(?MODULE, init, [[self(), RemoteNode]]).

-spec publish(pid(), term()) -> ok | {error, term()}.
publish(Pid, Msg) ->
    Ref = make_ref(),
    MRef = monitor(process, Pid),
    Pid ! {msg, self(), Ref, Msg},
    receive
        {Ref, R} ->
            demonitor(MRef, [flush]),
            R;
        {'DOWN', MRef, process, Pid, Reason} ->
            {error, Reason}
    end.

-spec enqueue(pid(), term(), boolean(), timeout()) -> ok | {error, term()}.
enqueue(Pid, Term, BufferIfUnreachable, Timeout) ->
    Ref = make_ref(),
    MRef = monitor(process, Pid),
    Pid ! {enq, self(), Ref, Term, BufferIfUnreachable},
    case Timeout of
        infinity ->
            receive
                {Ref, Reply} ->
                    demonitor(MRef, [flush]),
                    Reply;
                {'DOWN', MRef, process, Pid, Reason} ->
                    {error, Reason}
            end;
        _ ->
            receive
                {Ref, Reply} ->
                    demonitor(MRef, [flush]),
                    Reply;
                {'DOWN', MRef, process, Pid, Reason} ->
                    {error, Reason}
            after Timeout ->
                demonitor(MRef, [flush]),
                {error, timeout}
            end
    end.

-spec status(pid()) -> up | init | down | {error, timeout | term()}.
status(Pid) ->
    Timeout = application:get_env(vmq_server, cluster_node_status_timeout, 500),
    Ref = make_ref(),
    MRef = monitor(process, Pid),
    Pid ! {status, self(), Ref},
    receive
        {Ref, Reply} ->
            demonitor(MRef, [flush]),
            Reply;
        {'DOWN', MRef, process, Pid, Reason} ->
            {error, Reason}
    after Timeout ->
        lager:error("Timeout while trying to check cluster_node status"),
        demonitor(MRef, [flush]),
        {error, timeout}
    end.

init([Parent, RemoteNode]) ->
    process_flag(trap_exit, true),
    MaxQueueSize = vmq_config:get_env(outgoing_clustering_buffer_size),
    proc_lib:init_ack(Parent, {ok, self()}),
    % Delay the initial connect attempt, this is useful when automating
    % cluster node setup, where multiple nodes are concurrently setup.
    % Without a delay a node may try to connect to a cluster node that
    % hasn't finished setting up the vmq cluster listener.
    erlang:send_after(1000, self(), reconnect),
    loop(#state{parent = Parent, node = RemoteNode, max_queue_size = MaxQueueSize}).

loop(#state{pending = Pending, reachable = Reachable} = State) when
    Pending == [];
    Reachable == false
->
    receive
        M ->
            loop(handle_message(M, State))
    end;
loop(#state{} = State) ->
    receive
        M ->
            loop(handle_message(M, State))
    after 0 ->
        loop(internal_flush(State))
    end.

buffer_message(
    BinMsg,
    #state{
        pending = Pending,
        max_queue_size = Max,
        reachable = Reachable,
        bytes_dropped = {{M, S, _}, V}
    } = State
) ->
    {NewPending, Dropped} =
        case Reachable of
            true ->
                {[BinMsg | Pending], 0};
            false ->
                case iolist_size(Pending) < Max of
                    true ->
                        {[BinMsg | Pending], 0};
                    false ->
                        _ = vmq_metrics:incr_cluster_msg_drop(send_buffer_full),
                        {Pending, byte_size(BinMsg)}
                end
        end,
    NewBytesDropped =
        case os:timestamp() of
            {M, S, _} = TS ->
                {TS, V + Dropped};
            TS ->
                _ = vmq_metrics:incr_cluster_bytes_dropped(V + Dropped),
                {TS, 0}
        end,
    {Dropped, maybe_flush(State#state{pending = NewPending, bytes_dropped = NewBytesDropped})}.

handle_message(
    {enq, CallerPid, Ref, _, BufferIfUnreachable},
    #state{reachable = false} = State
) when
    BufferIfUnreachable =:= false
->
    CallerPid ! {Ref, {error, not_reachable}},
    State;
handle_message({enq, CallerPid, Ref, Term, _}, State) ->
    Bin = term_to_binary({CallerPid, Ref, Term}),
    L = byte_size(Bin),
    BinMsg = <<"enq", L:32, Bin/binary>>,
    %% buffering is allowed, but will only happen if the remote node
    %% is unreachable
    {Dropped, NewState} = buffer_message(BinMsg, State),
    case Dropped > 0 of
        true ->
            CallerPid ! {Ref, {error, buffer_full}};
        false ->
            %% reply directly from other node
            ignore
    end,
    NewState;
handle_message({msg, CallerPid, Ref, Msg}, State) ->
    Bin = term_to_binary(Msg),
    L = byte_size(Bin),
    BinMsg = <<"msg", L:32, Bin/binary>>,
    {Dropped, NewState} = buffer_message(BinMsg, State),
    case Dropped > 0 of
        true ->
            CallerPid ! {Ref, {error, buffer_full}};
        false ->
            CallerPid ! {Ref, ok}
    end,
    NewState;
handle_message(
    {connect_async_done, AsyncPid, {ok, {Transport, Socket}}},
    #state{async_connect_pid = AsyncPid, node = RemoteNode} = State
) ->
    NodeName = term_to_binary(node()),
    L = byte_size(NodeName),
    Msg = [<<"vmq-connect">>, <<L:32, NodeName/binary>>],
    case send(Transport, Socket, Msg) of
        ok ->
            lager:info("successfully connected to cluster node ~p", [RemoteNode]),
            State#state{
                socket = Socket,
                transport = Transport,
                %% !!! remote node is reachable
                async_connect_pid = undefined,
                reachable = true
            };
        {error, Reason} ->
            lager:error("can't initiate connect to cluster node ~p due to ~p", [
                RemoteNode, Reason
            ]),
            close_reconnect(State)
    end;
handle_message({connect_async_done, AsyncPid, error}, #state{async_connect_pid = AsyncPid} = State) ->
    % connect_async already logged the error details
    close_reconnect(State);
handle_message(reconnect, #state{reachable = false} = State) ->
    connect(State#state{reconnect_tref = undefined});
handle_message({status, CallerPid, Ref}, #state{socket = Socket, reachable = Reachable} = State) ->
    Status =
        case Reachable of
            true ->
                up;
            false when Socket == undefined ->
                init;
            false ->
                down
        end,
    CallerPid ! {Ref, Status},
    State;
handle_message({system, From, Request}, #state{parent = Parent} = State) ->
    sys:handle_system_msg(Request, From, Parent, ?MODULE, [], State);
handle_message({tcp_closed, Socket}, #state{node = RemoteNode, socket = Socket} = State) ->
    lager:error(
        "connection to node ~p has been closed, reconnect in ~pms",
        [RemoteNode, ?RECONNECT]
    ),
    close_reconnect(State);
handle_message(
    {tcp_error, Socket, Reason}, #state{node = RemoteNode, socket = Socket} = State
) ->
    lager:error(
        "connection to node ~p has been closed due to error ~p, reconnect in ~pms",
        [RemoteNode, Reason, ?RECONNECT]
    ),
    close_reconnect(State);
handle_message({'EXIT', Parent, Reason}, #state{parent = Parent} = State) ->
    State0 = flush_pending_on_shutdown(State),
    teardown(State0, Reason),
    exit(Reason);
handle_message({'EXIT', AsyncPid, Reason}, #state{async_connect_pid = AsyncPid} = State) ->
    case Reason of
        normal ->
            State;
        _ ->
            lager:warning("async connect to ~p died: ~p", [State#state.node, Reason]),
            close_reconnect(State)
    end;
handle_message({'EXIT', _Pid, _Reason}, State) ->
    State;
handle_message(Msg, #state{node = Node, reachable = Reachable} = State) ->
    lager:error(
        "got unknown message ~p for node ~p (reachable ~p)",
        [Msg, Node, Reachable]
    ),
    State.

% tcp-over-ethernet MSS 1460
-define(FLUSH_THRESHOLD, 0).
maybe_flush(#state{pending = Pending} = State) ->
    Threshold = vmq_config:get_env(
        cluster_node_flush_threshold, ?FLUSH_THRESHOLD
    ),
    case iolist_size(Pending) >= Threshold of
        true ->
            internal_flush(State);
        false ->
            State
    end.

internal_flush(#state{reachable = false} = State) ->
    State;
internal_flush(#state{pending = []} = State) ->
    State;
internal_flush(
    #state{
        pending = Pending,
        node = Node,
        transport = Transport,
        socket = Socket,
        bytes_send = {{M, S, _}, V}
    } = State
) ->
    L = iolist_size(Pending),
    Msg = [<<"vmq-send", L:32>> | lists:reverse(Pending)],
    case send(Transport, Socket, Msg) of
        ok ->
            NewBytesSend =
                case os:timestamp() of
                    {M, S, _} = TS ->
                        {TS, V + L};
                    TS ->
                        _ = vmq_metrics:incr_cluster_bytes_sent(V + L),
                        {TS, 0}
                end,
            State#state{pending = [], bytes_send = NewBytesSend};
        {error, Reason} ->
            lager:warning(
                "can't send ~p bytes to ~p due to ~p, reconnect!",
                [L, Node, Reason]
            ),
            close_reconnect(State)
    end.

flush_pending_on_shutdown(#state{reachable = false} = State) ->
    State;
flush_pending_on_shutdown(#state{socket = undefined} = State) ->
    State;
flush_pending_on_shutdown(#state{pending = []} = State) ->
    _ = (catch shutdown_write(State#state.transport, State#state.socket)),
    State;
flush_pending_on_shutdown(
    #state{
        pending = Pending,
        transport = Transport,
        socket = Socket,
        node = Node,
        bytes_send = {_, V}
    } = State
) ->
    L = iolist_size(Pending),
    Msg = [<<"vmq-send", L:32>> | lists:reverse(Pending)],
    case send(Transport, Socket, Msg) of
        ok ->
            lager:info("flushed ~p pending bytes to ~p on shutdown", [L, Node]),
            _ = vmq_metrics:incr_cluster_bytes_sent(V + L),
            _ = (catch shutdown_write(Transport, Socket)),
            State#state{pending = [], bytes_send = {os:timestamp(), 0}};
        {error, Reason} ->
            lager:error(
                "failed to flush ~p pending bytes to ~p on shutdown: ~p",
                [L, Node, Reason]
            ),
            State
    end.

connect(#state{node = RemoteNode, reachable = false} = State) ->
    Self = self(),
    ConnectAsyncPid = spawn_link(fun() -> connect_async(Self, RemoteNode) end),
    State#state{async_connect_pid = ConnectAsyncPid}.

connect_async(ParentPid, RemoteNode) ->
    ConnectOpts = vmq_config:get_env(outgoing_connect_options),
    % the outgoing_connect_params_module must implement the connect_params/1 function
    ConnectParamsMod = vmq_config:get_env(outgoing_connect_params_module),
    ConnectTimeout = vmq_config:get_env(outgoing_connect_timeout),
    Reply =
        case rpc:call(RemoteNode, ConnectParamsMod, connect_params, [node()]) of
            {Transport, Host, Port} ->
                case
                    connect(
                        Transport,
                        Host,
                        Port,
                        lists:usort([
                            binary,
                            {active, true}
                            | ConnectOpts
                        ]),
                        ConnectTimeout
                    )
                of
                    {ok, Socket} ->
                        % at least tune 'buffer'
                        {ok, BufSizes} = inet:getopts(Socket, [sndbuf, recbuf, buffer]),
                        BufSize = lists:max([Sz || {_, Sz} <- BufSizes]),
                        inet:setopts(Socket, [{buffer, BufSize}]),
                        case controlling_process(Transport, Socket, ParentPid) of
                            ok ->
                                {ok, {Transport, Socket}};
                            {error, Reason} ->
                                lager:debug("can't assign socket ownership to ~p due to ~p", [
                                    ParentPid, Reason
                                ]),
                                error
                        end;
                    {error, Reason} ->
                        lager:error("can't connect to cluster node ~p due to ~p", [
                            RemoteNode, Reason
                        ]),
                        error
                end;
            {badrpc, nodedown} ->
                %% we don't scream.. vmq_cluster_mon screams
                error;
            E ->
                lager:error("can't connect to cluster node ~p due to ~p", [RemoteNode, E]),
                error
        end,
    ParentPid ! {connect_async_done, self(), Reply}.

close_reconnect(#state{transport = Transport, socket = Socket} = State) ->
    close(Transport, Socket),
    State#state{
        async_connect_pid = undefined,
        reachable = false,
        socket = undefined,
        reconnect_tref = reconnect_timer()
    }.

reconnect_timer() ->
    erlang:send_after(?RECONNECT, self(), reconnect).

%% connect_params is called by a RPC
-spec connect_params(node()) ->
    {gen_tcp, inet:ip_address() | inet:hostname(), inet:port_number()}
    | {error, not_ready}.
connect_params(_Node) ->
    case whereis(vmq_server_sup) of
        undefined ->
            %% vmq_server app not ready
            {error, not_ready};
        _ ->
            Listeners = vmq_config:get_env(listeners),
            case proplists:get_value(vmq, Listeners) of
                undefined ->
                    exit("can't connect to cluster node");
                Config ->
                    connect_params(tcp, Config)
            end
    end.

connect_params(tcp, [{{Addr, Port}, _} | _]) ->
    {gen_tcp, Addr, Port};
connect_params(tcp, []) ->
    no_config.

send(gen_tcp, Socket, Msg) ->
    gen_tcp:send(Socket, Msg).

close(_, undefined) -> ok;
close(gen_tcp, Socket) -> gen_tcp:close(Socket).

shutdown_write(gen_tcp, Socket) -> gen_tcp:shutdown(Socket, write).

connect(gen_tcp, Host, Port, Opts, Timeout) ->
    gen_tcp:connect(Host, Port, Opts, Timeout).

controlling_process(gen_tcp, Socket, Pid) ->
    gen_tcp:controlling_process(Socket, Pid).

teardown(
    #state{
        socket = Socket,
        transport = Transport,
        async_connect_pid = AsyncPid,
        pending = Pending,
        node = Node,
        bytes_send = {_, SentV},
        bytes_dropped = {_, DroppedV}
    },
    Reason
) ->
    case AsyncPid of
        undefined -> ignore;
        Pid -> exit(Pid, normal)
    end,
    case length(Pending) of
        0 ->
            lager:debug("no pending messages to count, teardown complete"),
            ok;
        Count ->
            lager:warning(
                "teardown with ~p pending messages, enqueueing them to Redis", [Count]
            ),
            _ = lists:foreach(fun(Frame) -> enqueue_pending_redis(Frame, Node) end, Pending)
    end,
    _ =
        case SentV > 0 of
            true -> vmq_metrics:incr_cluster_bytes_sent(SentV);
            false -> ok
        end,
    _ =
        case DroppedV > 0 of
            true -> vmq_metrics:incr_cluster_bytes_dropped(DroppedV);
            false -> ok
        end,
    case Reason of
        normal ->
            lager:debug("remote node ~p handler normally stopped", [Node]);
        shutdown ->
            lager:info("remote node ~p handler stopped due to shutdown", [Node]);
        _ ->
            lager:error("remote node ~p handler stopped abnormally due to '~p'", [Node, Reason])
    end,
    close(Transport, Socket),
    ok.

enqueue_pending_redis(<<"msg", L:32, Bin:L/binary>>, Node) ->
    try binary_to_term(Bin) of
        {InMsg, Subs} when is_list(Subs) ->
            Msg = vmq_cluster_com:to_vmq_msg(InMsg),
            lists:foreach(
                fun({SubscriberId, SubInfo}) ->
                    case
                        vmq_state_store_backend:enqueue(
                            Node,
                            term_to_binary(SubscriberId),
                            term_to_binary({SubInfo, Msg})
                        )
                    of
                        ok ->
                            ok;
                        {error, _} = Err ->
                            _ = vmq_metrics:incr_cluster_msg_drop(teardown, 1),
                            catch vmq_reg:on_message_drop_hook(
                                SubscriberId, Msg, {pending_redis_enqueue_failed, Err}
                            )
                    end
                end,
                Subs
            );
        _ ->
            ignore
    catch
        Class:Reason ->
            lager:warning(
                "failed to decode pending cluster frame on teardown: ~p:~p", [Class, Reason]
            ),
            ignore
    end;
enqueue_pending_redis(_Frame, _Node) ->
    ignore.

system_continue(_, _, State) ->
    loop(State).

-spec system_terminate(any(), _, _, _) -> no_return().
system_terminate(Reason, _, _, State) -> teardown(State, Reason).

system_code_change(Misc, _, _, _) ->
    {ok, Misc}.
