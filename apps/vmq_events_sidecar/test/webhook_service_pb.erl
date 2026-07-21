-module(webhook_service_pb).

-export([get_service_names/0, get_rpc_names/1, find_rpc_def/2]).
-export([encode_msg/2, decode_msg/2]).

get_service_names() ->
    ['webhook.v1beta1.PluginService'].

get_rpc_names('webhook.v1beta1.PluginService') ->
    ['Event'].

find_rpc_def('webhook.v1beta1.PluginService', 'Event') ->
    #{name => 'Event',
      input => 'webhook.v1beta1.EventRequest',
      output => 'google.protobuf.Empty',
      input_stream => false,
      output_stream => false,
      opts => []};
find_rpc_def(_, _) ->
    error.

encode_msg(#{'google.protobuf.Empty' := _}, 'google.protobuf.Empty') ->
    <<>>;
encode_msg(_, 'google.protobuf.Empty') ->
    <<>>;
encode_msg(Msg, Type) ->
    event_request_pb:encode_msg(Msg, Type).

decode_msg(Bin, 'webhook.v1beta1.EventRequest') ->
    event_request_pb:decode_msg(Bin, 'webhook.v1beta1.EventRequest');
decode_msg(_Bin, 'google.protobuf.Empty') ->
    #{}.
