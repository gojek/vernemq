-module(vmq_cluster_com).
-include("vmq_server.hrl").
-behaviour(ranch_protocol).

%% API.
-export([start_link/4, start_link/3]).

-export([
    init/3,
    loop/1
]).

-export([to_vmq_msg/1]).

-record(st, {
    socket,
    parser_state,
    reg_view,
    proto_tag,
    bytes_recv = {os:timestamp(), 0}
}).

%% API.
start_link(Ref, _Socket, Transport, Opts) ->
    Pid = proc_lib:spawn_link(?MODULE, init, [Ref, Transport, Opts]),
    {ok, Pid}.
start_link(Ref, Transport, Opts) ->
    Pid = proc_lib:spawn_link(?MODULE, init, [Ref, Transport, Opts]),
    {ok, Pid}.
init(Ref, Transport, Opts) ->
    {ok, Socket} = ranch:handshake(Ref),

    RegView = vmq_config:get_env(default_reg_view, vmq_reg_redis_trie),

    process_flag(trap_exit, true),
    %% tune buffer sizes
    CfgBufSizes = proplists:get_value(buffer_sizes, Opts, undefined),
    HighWatermark = proplists:get_value(high_watermark, Opts, 8192),
    LowWatermark = proplists:get_value(low_watermark, Opts, 4096),
    HighMsgQWatermark = proplists:get_value(high_msgq_watermark, Opts, 8192),
    LowMsgQWatermark = proplists:get_value(low_msgq_watermark, Opts, 4096),
    case CfgBufSizes of
        undefined ->
            {ok, BufSizes} = inet:getopts(Socket, [sndbuf, recbuf, buffer]),
            BufSize = lists:max([Sz || {_, Sz} <- BufSizes]),
            inet:setopts(Socket, [{buffer, BufSize}]);
        [SndBuf, RecBuf, Buffer] ->
            inet:setopts(Socket, [{sndbuf, SndBuf}, {recbuf, RecBuf}, {buffer, Buffer}])
    end,
    inet:setopts(Socket, [
        {high_watermark, HighWatermark},
        {low_watermark, LowWatermark},
        {high_msgq_watermark, HighMsgQWatermark},
        {low_msgq_watermark, LowMsgQWatermark}
    ]),
    case active_once(Socket) of
        ok ->
            loop(#st{
                socket = Socket,
                reg_view = RegView,
                proto_tag = proto_tag(Transport)
            });
        {error, Reason} ->
            exit(Reason)
    end.

proto_tag(ranch_tcp) -> {tcp, tcp_closed, tcp_error}.

loop(#st{} = State) ->
    receive
        M ->
            loop(handle_message(M, State))
    end;
loop({exit, Reason, _State}) ->
    case Reason of
        shutdown -> ok;
        normal -> ok;
        _ -> lager:warning("terminate due to ~p", [Reason])
    end.

active_once(Socket) ->
    inet:setopts(Socket, [{active, once}]).

shutdown(Socket) ->
    gen_tcp:shutdown(Socket, write).

close(Socket) ->
    gen_tcp:close(Socket).

recv(Socket, Length, Timeout) ->
    gen_tcp:recv(Socket, Length, Timeout).

handle_message(
    {Proto, _, Data},
    #st{
        socket = Socket,
        parser_state = ParserState,
        proto_tag = {Proto, _, _},
        bytes_recv = {{M, S, _}, V}
    } = State
) ->
    case process_bytes(Data, ParserState, State) of
        {ok, NewParserState, _Count} ->
            case active_once(Socket) of
                ok ->
                    L = byte_size(Data),
                    NewBytesRecv =
                        case os:timestamp() of
                            {M, S, _} = TS ->
                                {TS, V + L};
                            TS ->
                                _ = vmq_metrics:incr_cluster_bytes_received(V + L),
                                {TS, 0}
                        end,
                    State#st{parser_state = NewParserState, bytes_recv = NewBytesRecv};
                {error, _InetError} ->
                    %% Socket has a problem (most possibly closed)
                    %% ther's not much we can do right now.
                    %% let's go down, and let the remote node
                    %% reconnect!
                    {exit, normal, State}
            end;
        {error, Reason} ->
            {exit, Reason, State}
    end;
handle_message({ProtoClosed, _}, #st{proto_tag = {_, ProtoClosed, _}} = State) ->
    %% we regard a tcp_closed as 'normal'
    {exit, normal, State};
handle_message({ProtoErr, _, Error}, #st{proto_tag = {_, _, ProtoErr}} = State) ->
    {exit, Error, State};
handle_message({'DOWN', _, process, _ClusterNodePid, Reason}, State) ->
    lager:error("cluster com process ~p received DOWN from cluster node due to ~p", [
        self(),
        Reason
    ]),
    close_connection(State),
    {exit, Reason, State};
handle_message({'EXIT', _Parent, Reason}, State) ->
    lager:error("cluster com process ~p received exit from parent ~p due to ~p", [
        self(),
        _Parent,
        Reason
    ]),
    close_connection(State),
    {exit, Reason, State}.

close_connection(#st{socket = Socket} = State) ->
    _ = shutdown(Socket),
    _ = drain(State),
    _ = close(Socket),
    ok.

-define(DRAIN_DEADLINE_MS, 2000).
-define(DRAIN_RECV_TIMEOUT_MS, 200).

drain(#st{socket = Socket, proto_tag = {Proto, _, _}} = State0) ->
    _ = inet:setopts(Socket, [{active, false}]),
    Deadline = erlang:monotonic_time(millisecond) + ?DRAIN_DEADLINE_MS,
    lager:error("draining cluster com socket"),
    {State, Acc0} = drain_mailbox(Proto, State0, {0, 0}),
    {Bytes, Msgs} = drain_loop(State, State#st.parser_state, Deadline, Acc0),
    _ = vmq_metrics:incr_cluster_drain_bytes(Bytes),
    _ = vmq_metrics:incr_cluster_drain_messages(Msgs),
    lager:info("drained cluster com socket: ~p bytes, ~p msgs", [Bytes, Msgs]),
    {Bytes, Msgs}.

drain_mailbox(Proto, #st{parser_state = ParserState} = State, {Bytes, Msgs} = Acc) ->
    receive
        {Proto, _, Data} ->
            case process_bytes(Data, ParserState, State) of
                {ok, NewParserState, N} ->
                    NewAcc = {Bytes + byte_size(Data), Msgs + N},
                    drain_mailbox(Proto, State#st{parser_state = NewParserState}, NewAcc);
                {error, Reason} ->
                    lager:error(
                        "drain stopped after ~p msgs, can't process mailbox data: ~p",
                        [Msgs, Reason]
                    ),
                    {State, Acc}
            end
    after 0 ->
        {State, Acc}
    end.

drain_loop(#st{socket = Socket} = State, ParserState, Deadline, {Bytes, Msgs} = Acc) ->
    Now = erlang:monotonic_time(millisecond),
    case Deadline - Now of
        Remaining when Remaining =< 0 ->
            Acc;
        Remaining ->
            Timeout = min(?DRAIN_RECV_TIMEOUT_MS, Remaining),
            case recv(Socket, 0, Timeout) of
                {ok, Data} ->
                    case process_bytes(Data, ParserState, State) of
                        {ok, NewParserState, N} ->
                            NewAcc = {Bytes + byte_size(Data), Msgs + N},
                            drain_loop(State, NewParserState, Deadline, NewAcc);
                        {error, Reason} ->
                            lager:error(
                                "drain stopped after ~p msgs, can't process in-flight data: ~p",
                                [Msgs, Reason]
                            ),
                            Acc
                    end;
                {error, closed} ->
                    Acc;
                {error, _} ->
                    Acc
            end
    end.

process_bytes(<<"vmq-connect", L:32, BNodeName:L/binary, Rest/binary>>, undefined, St) ->
    NodeName = binary_to_term(BNodeName),
    case vmq_cluster_node_sup:get_cluster_node(NodeName) of
        {ok, ClusterNodePid} ->
            monitor(process, ClusterNodePid),
            process_bytes(Rest, <<>>, St);
        {error, not_found} ->
            {error, remote_node_not_available}
    end;
process_bytes(Bytes, Buffer, St) ->
    process_bytes(Bytes, Buffer, St, 0).

process_bytes(Bytes, Buffer, St, Acc) ->
    NewBuffer = <<Buffer/binary, Bytes/binary>>,
    case NewBuffer of
        <<"vmq-send", L:32, BFrames:L/binary, Rest/binary>> ->
            N = process(BFrames, St),
            process_bytes(Rest, <<>>, St, Acc + N);
        _ ->
            %% if we have received something else than "vmq-send" we
            %% will buffer everything unbounded forever and ever!
            {ok, NewBuffer, Acc}
    end.

process(Bin, St) ->
    process(Bin, St, 0).

process(<<"msg", L:32, Bin:L/binary, Rest/binary>>, St, N) ->
    {InMsg, Subs} = binary_to_term(Bin),
    Msg = to_vmq_msg(InMsg),
    _ = vmq_reg:enq_to_local_subs(Subs, Msg),
    process(Rest, St, N + 1);
process(<<"enq", L:32, Bin:L/binary, Rest/binary>>, St, N) ->
    case binary_to_term(Bin) of
        {CallerPid, Ref, {enqueue, QueuePid, Msgs}} ->
            %% enqueue in own process context
            %% to ensure that this won't block
            %% the cluster communication.
            spawn(fun() ->
                try
                    Reply = vmq_queue:enqueue_many(QueuePid, to_vmq_msgs(Msgs)),
                    CallerPid ! {Ref, Reply}
                catch
                    _:_ ->
                        CallerPid ! {Ref, {error, cant_remote_enqueue}}
                end
            end);
        {CallerPid, Ref, {enqueue_many, SubscriberId, Msgs, Opts}} ->
            %% enqueue in own process context
            %% to ensure that this won't block
            %% the cluster communication.
            spawn(fun() ->
                try
                    case vmq_queue_sup_sup:get_queue_pid(SubscriberId) of
                        QueuePid when is_pid(QueuePid) ->
                            Reply = vmq_queue:enqueue_many(QueuePid, Msgs, Opts),
                            CallerPid ! {Ref, Reply};
                        not_found ->
                            CallerPid ! {Ref, {error, subscriber_not_found}}
                    end
                catch
                    _:_ ->
                        CallerPid ! {Ref, {error, cant_remote_enqueue}}
                end
            end);
        Unknown ->
            lager:warning("unknown enqueue message: ~p", [Unknown])
    end,
    process(Rest, St, N + 1);
process(<<>>, _, N) ->
    N;
process(<<Cmd:3/binary, L:32, _:L/binary, Rest/binary>>, St, N) ->
    lager:warning("unknown message: ~p", [Cmd]),
    process(Rest, St, N).

to_vmq_msgs(Msgs) ->
    lists:map(
        fun({deliver, QoS, Msg}) ->
            {deliver, QoS, to_vmq_msg(Msg)}
        end,
        Msgs
    ).

to_vmq_msg(#vmq_msg{} = Msg) ->
    Msg;
to_vmq_msg(
    {vmq_msg, MsgRef, RoutingKey, Payload, Retain, Dup, QoS, Mountpoint, Persisted, SGPolicy,
        NonRetry, NonPersistence, ACLName}
) ->
    %% Pre-MQTT5 msg record. Fill in the missing ones.
    #vmq_msg{
        msg_ref = MsgRef,
        routing_key = RoutingKey,
        payload = Payload,
        retain = Retain,
        dup = Dup,
        qos = QoS,
        mountpoint = Mountpoint,
        persisted = Persisted,
        sg_policy = SGPolicy,
        properties = #{},
        expiry_ts = undefined,
        non_retry = NonRetry,
        non_persistence = NonPersistence,
        acl_name = ACLName
    };
to_vmq_msg(InMsg) when
    is_tuple(InMsg),
    size(InMsg) > size(#vmq_msg{})
->
    %% we have a msg with unknown elements. As we don't know
    %% how to handle those we strip them away and fill the
    %% rest into the `vmq_msg` record we know.
    #vmq_msg{
        msg_ref = element(2, InMsg),
        routing_key = element(3, InMsg),
        payload = element(4, InMsg),
        retain = element(5, InMsg),
        dup = element(6, InMsg),
        qos = element(7, InMsg),
        mountpoint = element(8, InMsg),
        persisted = element(9, InMsg),
        sg_policy = element(10, InMsg),
        properties = element(11, InMsg),
        expiry_ts = element(12, InMsg),
        non_retry = element(13, InMsg),
        non_persistence = element(14, InMsg),
        acl_name = element(15, InMsg),
        pub_msg_id = element(16, InMsg),
        pub_pid = element(17, InMsg)
    }.
