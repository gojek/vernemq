-module(vmq_cluster).

-include_lib("vmq_commons/include/vmq_types.hrl").

-export([
    publish/3,
    remote_enqueue/3,
    remote_enqueue/4
]).

%%%===================================================================
%%% API
%%%===================================================================

-spec publish(RemoteNode :: node(), Subscribers :: [{subscriber_id(), subinfo()}], Msg :: msg()) ->
    ok | {error, term()}.
publish(RemoteNode, Subscribers, Msg) ->
    case vmq_cluster_node_sup:get_cluster_node(RemoteNode) of
        {error, not_found} ->
            Err = remote_node_pid_not_found,
            vmq_metrics:incr_cluster_msg_drop(Err),
            {error, Err};
        {ok, Pid} ->
            vmq_cluster_node:publish(Pid, {Msg, Subscribers})
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
            {error, remote_node_pid_not_found};
        {ok, Pid} ->
            vmq_cluster_node:enqueue(Pid, Term, BufferIfUnreachable, Timeout)
    end.
