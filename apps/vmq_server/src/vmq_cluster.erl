-module(vmq_cluster).

-include_lib("vmq_commons/include/vmq_types.hrl").

-export([
    publish/2,
    remote_enqueue/3,
    remote_enqueue/4,
    remote_enqueue_async/3
]).

%%%===================================================================
%%% API
%%%===================================================================

-spec publish(_, _) -> any().
publish(Node, Msg) ->
    case vmq_cluster_node_sup:get_cluster_node(Node) of
        {error, not_found} ->
            {error, not_found};
        {ok, Pid} ->
            case vmq_cluster_node:publish(Pid, Msg) of
                {error, timeout} = Err ->
                    on_message_drop_timeout(Msg),
                    Err;
                Reply ->
                    Reply
            end
    end.

-spec remote_enqueue(node(), Term, BufferIfUnreachable) ->
    ok | {error, term()}
when
    Term ::
        {enqueue_many, subscriber_id(), Msgs :: term(), Opts :: map()}
        | {enqueue, Queue :: term(), Msgs :: term()},
    BufferIfUnreachable :: boolean().
remote_enqueue(Node, Term, BufferIfUnreachable) ->
    Timeout = vmq_config:get_env(remote_enqueue_timeout),
    remote_enqueue(Node, Term, BufferIfUnreachable, Timeout).

-spec remote_enqueue(node(), Term, BufferIfUnreachable, Timeout) ->
    ok | {error, term()}
when
    Term ::
        {enqueue_many, subscriber_id(), Msgs :: term(), Opts :: map()}
        | {enqueue, Queue :: term(), Msgs :: term()},
    BufferIfUnreachable :: boolean(),
    Timeout :: non_neg_integer() | infinity.
remote_enqueue(Node, Term, BufferIfUnreachable, Timeout) ->
    case vmq_cluster_node_sup:get_cluster_node(Node) of
        {error, not_found} ->
            {error, not_found};
        {ok, Pid} ->
            vmq_cluster_node:enqueue(Pid, Term, BufferIfUnreachable, Timeout)
    end.

remote_enqueue_async(Node, Term, BufferIfUnreachable) ->
    case vmq_cluster_node_sup:get_cluster_node(Node) of
        {error, not_found} ->
            {error, not_found};
        {ok, Pid} ->
            vmq_cluster_node:enqueue_async(Pid, Term, BufferIfUnreachable)
    end.

%%%===================================================================
%%% Internal functions
%%%===================================================================

on_message_drop_timeout(
    #vmq_msg{
        mountpoint = MP,
        routing_key = Topic,
        qos = QoS,
        payload = Payload,
        retain = IsRetain,
        acl_name = AclName,
        pub_pid = PubPid
    }
) ->
    {SubscriberId, SessionId} =
        case vmq_mqtt_fsm:info(PubPid, [subscriber_id, session_id]) of
            {ok, Items} ->
                SId = proplists:get_value(subscriber_id, Items, {MP, undefined}),
                SessId = proplists:get_value(session_id, Items, undefined),
                {SId, SessId};
            _ ->
                {{MP, undefined}, undefined}
        end,
    _ = vmq_plugin:all(on_message_drop, [
        SubscriberId,
        fun() -> {Topic, QoS, Payload, #{is_retain => IsRetain}, #matched_acl{name = AclName}} end,
        cluster_publish_timeout,
        SessionId
    ]),
    ok;
on_message_drop_timeout(_) ->
    ok.
