%% -*- coding: utf-8 -*-
%% @private
%% Automatically generated, do not edit
%% Generated by gpb_compile version 4.20.0
%% Version source: file
-module(disconnect_reason_pb).

-export([encode_msg/1, encode_msg/2, encode_msg/3]).
-export([decode_msg/2, decode_msg/3]).
-export([merge_msgs/2, merge_msgs/3, merge_msgs/4]).
-export([verify_msg/1, verify_msg/2, verify_msg/3]).
-export([get_msg_defs/0]).
-export([get_msg_names/0]).
-export([get_group_names/0]).
-export([get_msg_or_group_names/0]).
-export([get_enum_names/0]).
-export([find_msg_def/1, fetch_msg_def/1]).
-export([find_enum_def/1, fetch_enum_def/1]).
-export([enum_symbol_by_value/2, enum_value_by_symbol/2]).
-export([
    'enum_symbol_by_value_eventssidecar.v1.Reason'/1,
    'enum_value_by_symbol_eventssidecar.v1.Reason'/1
]).
-export([get_service_names/0]).
-export([get_service_def/1]).
-export([get_rpc_names/1]).
-export([find_rpc_def/2, fetch_rpc_def/2]).
-export([fqbin_to_service_name/1]).
-export([service_name_to_fqbin/1]).
-export([fqbins_to_service_and_rpc_name/2]).
-export([service_and_rpc_name_to_fqbins/2]).
-export([fqbin_to_msg_name/1]).
-export([msg_name_to_fqbin/1]).
-export([fqbin_to_enum_name/1]).
-export([enum_name_to_fqbin/1]).
-export([get_package_name/0]).
-export([uses_packages/0]).
-export([source_basename/0]).
-export([get_all_source_basenames/0]).
-export([get_all_proto_names/0]).
-export([get_msg_containment/1]).
-export([get_pkg_containment/1]).
-export([get_service_containment/1]).
-export([get_rpc_containment/1]).
-export([get_enum_containment/1]).
-export([get_proto_by_msg_name_as_fqbin/1]).
-export([get_proto_by_service_name_as_fqbin/1]).
-export([get_proto_by_enum_name_as_fqbin/1]).
-export([get_protos_by_pkg_name_as_fqbin/1]).
-export([gpb_version_as_string/0, gpb_version_as_list/0]).
-export([gpb_version_source/0]).

-include("disconnect_reason_pb.hrl").
-include("gpb.hrl").

%% enumerated types
-type 'eventssidecar.v1.Reason'() ::
    'REASON_UNSPECIFIED'
    | 'REASON_NOT_AUTHORIZED'
    | 'REASON_NORMAL_DISCONNECT'
    | 'REASON_SESSION_TAKEN_OVER'
    | 'REASON_ADMINISTRATIVE_ACTION'
    | 'REASON_DISCONNECT_KEEP_ALIVE'
    | 'REASON_DISCONNECT_MIGRATION'
    | 'REASON_BAD_AUTHENTICATION_METHOD'
    | 'REASON_REMOTE_SESSION_TAKEN_OVER'
    | 'REASON_MQTT_CLIENT_DISCONNECT'
    | 'REASON_RECEIVE_MAX_EXCEEDED'
    | 'REASON_PROTOCOL_ERROR'
    | 'REASON_PUBLISH_AUTH_ERROR'
    | 'REASON_INVALID_PUBREC_ERROR'
    | 'REASON_INVALID_PUBCOMP_ERROR'
    | 'REASON_UNEXPECTED_FRAME_TYPE'
    | 'REASON_EXIT_SIGNAL_RECEIVED'
    | 'REASON_TCP_CLOSED'.
-export_type(['eventssidecar.v1.Reason'/0]).

%% message types

-export_type([]).
-type '$msg_name'() :: none().
-type '$msg'() :: none().
-export_type(['$msg_name'/0, '$msg'/0]).

-spec encode_msg(_) -> no_return().
encode_msg(Msg) -> encode_msg(Msg, dummy_name, []).

-spec encode_msg(_, _) -> no_return().
encode_msg(Msg, MsgName) when is_atom(MsgName) -> encode_msg(Msg, MsgName, []);
encode_msg(Msg, Opts) when tuple_size(Msg) >= 1, is_list(Opts) ->
    encode_msg(Msg, element(1, Msg), []).

-spec encode_msg(_, _, _) -> no_return().
encode_msg(_Msg, _MsgName, _Opts) -> erlang:error({gpb_error, no_messages}).

-compile({nowarn_unused_function, e_type_sint/3}).
e_type_sint(Value, Bin, _TrUserData) when Value >= 0 -> e_varint(Value * 2, Bin);
e_type_sint(Value, Bin, _TrUserData) -> e_varint(Value * -2 - 1, Bin).

-compile({nowarn_unused_function, e_type_int32/3}).
e_type_int32(Value, Bin, _TrUserData) when 0 =< Value, Value =< 127 -> <<Bin/binary, Value>>;
e_type_int32(Value, Bin, _TrUserData) ->
    <<N:64/unsigned-native>> = <<Value:64/signed-native>>,
    e_varint(N, Bin).

-compile({nowarn_unused_function, e_type_int64/3}).
e_type_int64(Value, Bin, _TrUserData) when 0 =< Value, Value =< 127 -> <<Bin/binary, Value>>;
e_type_int64(Value, Bin, _TrUserData) ->
    <<N:64/unsigned-native>> = <<Value:64/signed-native>>,
    e_varint(N, Bin).

-compile({nowarn_unused_function, e_type_bool/3}).
e_type_bool(true, Bin, _TrUserData) -> <<Bin/binary, 1>>;
e_type_bool(false, Bin, _TrUserData) -> <<Bin/binary, 0>>;
e_type_bool(1, Bin, _TrUserData) -> <<Bin/binary, 1>>;
e_type_bool(0, Bin, _TrUserData) -> <<Bin/binary, 0>>.

-compile({nowarn_unused_function, e_type_string/3}).
e_type_string(S, Bin, _TrUserData) ->
    Utf8 = unicode:characters_to_binary(S),
    Bin2 = e_varint(byte_size(Utf8), Bin),
    <<Bin2/binary, Utf8/binary>>.

-compile({nowarn_unused_function, e_type_bytes/3}).
e_type_bytes(Bytes, Bin, _TrUserData) when is_binary(Bytes) ->
    Bin2 = e_varint(byte_size(Bytes), Bin),
    <<Bin2/binary, Bytes/binary>>;
e_type_bytes(Bytes, Bin, _TrUserData) when is_list(Bytes) ->
    BytesBin = iolist_to_binary(Bytes),
    Bin2 = e_varint(byte_size(BytesBin), Bin),
    <<Bin2/binary, BytesBin/binary>>.

-compile({nowarn_unused_function, e_type_fixed32/3}).
e_type_fixed32(Value, Bin, _TrUserData) -> <<Bin/binary, Value:32/little>>.

-compile({nowarn_unused_function, e_type_sfixed32/3}).
e_type_sfixed32(Value, Bin, _TrUserData) -> <<Bin/binary, Value:32/little-signed>>.

-compile({nowarn_unused_function, e_type_fixed64/3}).
e_type_fixed64(Value, Bin, _TrUserData) -> <<Bin/binary, Value:64/little>>.

-compile({nowarn_unused_function, e_type_sfixed64/3}).
e_type_sfixed64(Value, Bin, _TrUserData) -> <<Bin/binary, Value:64/little-signed>>.

-compile({nowarn_unused_function, e_type_float/3}).
e_type_float(V, Bin, _) when is_number(V) -> <<Bin/binary, V:32/little-float>>;
e_type_float(infinity, Bin, _) -> <<Bin/binary, 0:16, 128, 127>>;
e_type_float('-infinity', Bin, _) -> <<Bin/binary, 0:16, 128, 255>>;
e_type_float(nan, Bin, _) -> <<Bin/binary, 0:16, 192, 127>>.

-compile({nowarn_unused_function, e_type_double/3}).
e_type_double(V, Bin, _) when is_number(V) -> <<Bin/binary, V:64/little-float>>;
e_type_double(infinity, Bin, _) -> <<Bin/binary, 0:48, 240, 127>>;
e_type_double('-infinity', Bin, _) -> <<Bin/binary, 0:48, 240, 255>>;
e_type_double(nan, Bin, _) -> <<Bin/binary, 0:48, 248, 127>>.

-compile({nowarn_unused_function, e_unknown_elems/2}).
e_unknown_elems([Elem | Rest], Bin) ->
    BinR =
        case Elem of
            {varint, FNum, N} ->
                BinF = e_varint(FNum bsl 3, Bin),
                e_varint(N, BinF);
            {length_delimited, FNum, Data} ->
                BinF = e_varint(FNum bsl 3 bor 2, Bin),
                BinL = e_varint(byte_size(Data), BinF),
                <<BinL/binary, Data/binary>>;
            {group, FNum, GroupFields} ->
                Bin1 = e_varint(FNum bsl 3 bor 3, Bin),
                Bin2 = e_unknown_elems(GroupFields, Bin1),
                e_varint(FNum bsl 3 bor 4, Bin2);
            {fixed32, FNum, V} ->
                BinF = e_varint(FNum bsl 3 bor 5, Bin),
                <<BinF/binary, V:32/little>>;
            {fixed64, FNum, V} ->
                BinF = e_varint(FNum bsl 3 bor 1, Bin),
                <<BinF/binary, V:64/little>>
        end,
    e_unknown_elems(Rest, BinR);
e_unknown_elems([], Bin) ->
    Bin.

-compile({nowarn_unused_function, e_varint/3}).
e_varint(N, Bin, _TrUserData) -> e_varint(N, Bin).

-compile({nowarn_unused_function, e_varint/2}).
e_varint(N, Bin) when N =< 127 -> <<Bin/binary, N>>;
e_varint(N, Bin) ->
    Bin2 = <<Bin/binary, (N band 127 bor 128)>>,
    e_varint(N bsr 7, Bin2).

-spec decode_msg(binary(), atom()) -> no_return().
decode_msg(Bin, _MsgName) when is_binary(Bin) -> erlang:error({gpb_error, no_messages}).

-spec decode_msg(binary(), atom(), list()) -> no_return().
decode_msg(Bin, _MsgName, _Opts) when is_binary(Bin) -> erlang:error({gpb_error, no_messages}).

-spec merge_msgs(_, _) -> no_return().
merge_msgs(Prev, New) -> merge_msgs(Prev, New, []).

-spec merge_msgs(_, _, _) -> no_return().
merge_msgs(_Prev, _New, _MsgNameOrOpts) -> erlang:error({gpb_error, no_messages}).

merge_msgs(_Prev, _New, _MsgName, _Opts) -> erlang:error({gpb_error, no_messages}).

-spec verify_msg(_) -> no_return().
verify_msg(Msg) -> verify_msg(Msg, []).

-spec verify_msg(_, _) -> no_return().
verify_msg(Msg, _OptsOrMsgName) -> mk_type_error(not_a_known_message, Msg, []).

-spec verify_msg(_, _, _) -> no_return().
verify_msg(Msg, _MsgName, _Opts) -> mk_type_error(not_a_known_message, Msg, []).

-compile({nowarn_unused_function, mk_type_error/3}).
-spec mk_type_error(_, _, list()) -> no_return().
mk_type_error(Error, ValueSeen, Path) ->
    Path2 = prettify_path(Path),
    erlang:error({gpb_type_error, {Error, [{value, ValueSeen}, {path, Path2}]}}).

prettify_path([]) -> top_level.

-compile({nowarn_unused_function, id/2}).
-compile({inline, id/2}).
id(X, _TrUserData) -> X.

-compile({nowarn_unused_function, v_ok/3}).
-compile({inline, v_ok/3}).
v_ok(_Value, _Path, _TrUserData) -> ok.

-compile({nowarn_unused_function, m_overwrite/3}).
-compile({inline, m_overwrite/3}).
m_overwrite(_Prev, New, _TrUserData) -> New.

-compile({nowarn_unused_function, cons/3}).
-compile({inline, cons/3}).
cons(Elem, Acc, _TrUserData) -> [Elem | Acc].

-compile({nowarn_unused_function, lists_reverse/2}).
-compile({inline, lists_reverse/2}).
'lists_reverse'(L, _TrUserData) -> lists:reverse(L).
-compile({nowarn_unused_function, 'erlang_++'/3}).
-compile({inline, 'erlang_++'/3}).
'erlang_++'(A, B, _TrUserData) -> A ++ B.

get_msg_defs() ->
    [
        {{enum, 'eventssidecar.v1.Reason'}, [
            {'REASON_UNSPECIFIED', 0},
            {'REASON_NOT_AUTHORIZED', 1},
            {'REASON_NORMAL_DISCONNECT', 2},
            {'REASON_SESSION_TAKEN_OVER', 3},
            {'REASON_ADMINISTRATIVE_ACTION', 4},
            {'REASON_DISCONNECT_KEEP_ALIVE', 5},
            {'REASON_DISCONNECT_MIGRATION', 6},
            {'REASON_BAD_AUTHENTICATION_METHOD', 7},
            {'REASON_REMOTE_SESSION_TAKEN_OVER', 8},
            {'REASON_MQTT_CLIENT_DISCONNECT', 9},
            {'REASON_RECEIVE_MAX_EXCEEDED', 10},
            {'REASON_PROTOCOL_ERROR', 11},
            {'REASON_PUBLISH_AUTH_ERROR', 12},
            {'REASON_INVALID_PUBREC_ERROR', 13},
            {'REASON_INVALID_PUBCOMP_ERROR', 14},
            {'REASON_UNEXPECTED_FRAME_TYPE', 15},
            {'REASON_EXIT_SIGNAL_RECEIVED', 16},
            {'REASON_TCP_CLOSED', 17}
        ]}
    ].

get_msg_names() -> [].

get_group_names() -> [].

get_msg_or_group_names() -> [].

get_enum_names() -> ['eventssidecar.v1.Reason'].

-spec fetch_msg_def(_) -> no_return().
fetch_msg_def(MsgName) -> erlang:error({no_such_msg, MsgName}).

fetch_enum_def(EnumName) ->
    case find_enum_def(EnumName) of
        Es when is_list(Es) -> Es;
        error -> erlang:error({no_such_enum, EnumName})
    end.

find_msg_def(_) -> error.

find_enum_def('eventssidecar.v1.Reason') ->
    [
        {'REASON_UNSPECIFIED', 0},
        {'REASON_NOT_AUTHORIZED', 1},
        {'REASON_NORMAL_DISCONNECT', 2},
        {'REASON_SESSION_TAKEN_OVER', 3},
        {'REASON_ADMINISTRATIVE_ACTION', 4},
        {'REASON_DISCONNECT_KEEP_ALIVE', 5},
        {'REASON_DISCONNECT_MIGRATION', 6},
        {'REASON_BAD_AUTHENTICATION_METHOD', 7},
        {'REASON_REMOTE_SESSION_TAKEN_OVER', 8},
        {'REASON_MQTT_CLIENT_DISCONNECT', 9},
        {'REASON_RECEIVE_MAX_EXCEEDED', 10},
        {'REASON_PROTOCOL_ERROR', 11},
        {'REASON_PUBLISH_AUTH_ERROR', 12},
        {'REASON_INVALID_PUBREC_ERROR', 13},
        {'REASON_INVALID_PUBCOMP_ERROR', 14},
        {'REASON_UNEXPECTED_FRAME_TYPE', 15},
        {'REASON_EXIT_SIGNAL_RECEIVED', 16},
        {'REASON_TCP_CLOSED', 17}
    ];
find_enum_def(_) ->
    error.

enum_symbol_by_value('eventssidecar.v1.Reason', Value) ->
    'enum_symbol_by_value_eventssidecar.v1.Reason'(Value).

enum_value_by_symbol('eventssidecar.v1.Reason', Sym) ->
    'enum_value_by_symbol_eventssidecar.v1.Reason'(Sym).

'enum_symbol_by_value_eventssidecar.v1.Reason'(0) -> 'REASON_UNSPECIFIED';
'enum_symbol_by_value_eventssidecar.v1.Reason'(1) -> 'REASON_NOT_AUTHORIZED';
'enum_symbol_by_value_eventssidecar.v1.Reason'(2) -> 'REASON_NORMAL_DISCONNECT';
'enum_symbol_by_value_eventssidecar.v1.Reason'(3) -> 'REASON_SESSION_TAKEN_OVER';
'enum_symbol_by_value_eventssidecar.v1.Reason'(4) -> 'REASON_ADMINISTRATIVE_ACTION';
'enum_symbol_by_value_eventssidecar.v1.Reason'(5) -> 'REASON_DISCONNECT_KEEP_ALIVE';
'enum_symbol_by_value_eventssidecar.v1.Reason'(6) -> 'REASON_DISCONNECT_MIGRATION';
'enum_symbol_by_value_eventssidecar.v1.Reason'(7) -> 'REASON_BAD_AUTHENTICATION_METHOD';
'enum_symbol_by_value_eventssidecar.v1.Reason'(8) -> 'REASON_REMOTE_SESSION_TAKEN_OVER';
'enum_symbol_by_value_eventssidecar.v1.Reason'(9) -> 'REASON_MQTT_CLIENT_DISCONNECT';
'enum_symbol_by_value_eventssidecar.v1.Reason'(10) -> 'REASON_RECEIVE_MAX_EXCEEDED';
'enum_symbol_by_value_eventssidecar.v1.Reason'(11) -> 'REASON_PROTOCOL_ERROR';
'enum_symbol_by_value_eventssidecar.v1.Reason'(12) -> 'REASON_PUBLISH_AUTH_ERROR';
'enum_symbol_by_value_eventssidecar.v1.Reason'(13) -> 'REASON_INVALID_PUBREC_ERROR';
'enum_symbol_by_value_eventssidecar.v1.Reason'(14) -> 'REASON_INVALID_PUBCOMP_ERROR';
'enum_symbol_by_value_eventssidecar.v1.Reason'(15) -> 'REASON_UNEXPECTED_FRAME_TYPE';
'enum_symbol_by_value_eventssidecar.v1.Reason'(16) -> 'REASON_EXIT_SIGNAL_RECEIVED';
'enum_symbol_by_value_eventssidecar.v1.Reason'(17) -> 'REASON_TCP_CLOSED'.

'enum_value_by_symbol_eventssidecar.v1.Reason'('REASON_UNSPECIFIED') -> 0;
'enum_value_by_symbol_eventssidecar.v1.Reason'('REASON_NOT_AUTHORIZED') -> 1;
'enum_value_by_symbol_eventssidecar.v1.Reason'('REASON_NORMAL_DISCONNECT') -> 2;
'enum_value_by_symbol_eventssidecar.v1.Reason'('REASON_SESSION_TAKEN_OVER') -> 3;
'enum_value_by_symbol_eventssidecar.v1.Reason'('REASON_ADMINISTRATIVE_ACTION') -> 4;
'enum_value_by_symbol_eventssidecar.v1.Reason'('REASON_DISCONNECT_KEEP_ALIVE') -> 5;
'enum_value_by_symbol_eventssidecar.v1.Reason'('REASON_DISCONNECT_MIGRATION') -> 6;
'enum_value_by_symbol_eventssidecar.v1.Reason'('REASON_BAD_AUTHENTICATION_METHOD') -> 7;
'enum_value_by_symbol_eventssidecar.v1.Reason'('REASON_REMOTE_SESSION_TAKEN_OVER') -> 8;
'enum_value_by_symbol_eventssidecar.v1.Reason'('REASON_MQTT_CLIENT_DISCONNECT') -> 9;
'enum_value_by_symbol_eventssidecar.v1.Reason'('REASON_RECEIVE_MAX_EXCEEDED') -> 10;
'enum_value_by_symbol_eventssidecar.v1.Reason'('REASON_PROTOCOL_ERROR') -> 11;
'enum_value_by_symbol_eventssidecar.v1.Reason'('REASON_PUBLISH_AUTH_ERROR') -> 12;
'enum_value_by_symbol_eventssidecar.v1.Reason'('REASON_INVALID_PUBREC_ERROR') -> 13;
'enum_value_by_symbol_eventssidecar.v1.Reason'('REASON_INVALID_PUBCOMP_ERROR') -> 14;
'enum_value_by_symbol_eventssidecar.v1.Reason'('REASON_UNEXPECTED_FRAME_TYPE') -> 15;
'enum_value_by_symbol_eventssidecar.v1.Reason'('REASON_EXIT_SIGNAL_RECEIVED') -> 16;
'enum_value_by_symbol_eventssidecar.v1.Reason'('REASON_TCP_CLOSED') -> 17.

get_service_names() -> [].

get_service_def(_) -> error.

get_rpc_names(_) -> error.

find_rpc_def(_, _) -> error.

-spec fetch_rpc_def(_, _) -> no_return().
fetch_rpc_def(ServiceName, RpcName) -> erlang:error({no_such_rpc, ServiceName, RpcName}).

%% Convert a a fully qualified (ie with package name) service name
%% as a binary to a service name as an atom.
-spec fqbin_to_service_name(_) -> no_return().
fqbin_to_service_name(X) -> error({gpb_error, {badservice, X}}).

%% Convert a service name as an atom to a fully qualified
%% (ie with package name) name as a binary.
-spec service_name_to_fqbin(_) -> no_return().
service_name_to_fqbin(X) -> error({gpb_error, {badservice, X}}).

%% Convert a a fully qualified (ie with package name) service name
%% and an rpc name, both as binaries to a service name and an rpc
%% name, as atoms.
-spec fqbins_to_service_and_rpc_name(_, _) -> no_return().
fqbins_to_service_and_rpc_name(S, R) -> error({gpb_error, {badservice_or_rpc, {S, R}}}).

%% Convert a service name and an rpc name, both as atoms,
%% to a fully qualified (ie with package name) service name and
%% an rpc name as binaries.
-spec service_and_rpc_name_to_fqbins(_, _) -> no_return().
service_and_rpc_name_to_fqbins(S, R) -> error({gpb_error, {badservice_or_rpc, {S, R}}}).

-spec fqbin_to_msg_name(_) -> no_return().
fqbin_to_msg_name(E) -> error({gpb_error, {badmsg, E}}).

-spec msg_name_to_fqbin(_) -> no_return().
msg_name_to_fqbin(E) -> error({gpb_error, {badmsg, E}}).

fqbin_to_enum_name(<<"eventssidecar.v1.Reason">>) -> 'eventssidecar.v1.Reason';
fqbin_to_enum_name(E) -> error({gpb_error, {badenum, E}}).

enum_name_to_fqbin('eventssidecar.v1.Reason') -> <<"eventssidecar.v1.Reason">>;
enum_name_to_fqbin(E) -> error({gpb_error, {badenum, E}}).

get_package_name() -> 'eventssidecar.v1'.

%% Whether or not the message names
%% are prepended with package name or not.
uses_packages() -> true.

source_basename() -> "disconnect_reason.proto".

%% Retrieve all proto file names, also imported ones.
%% The order is top-down. The first element is always the main
%% source file. The files are returned with extension,
%% see get_all_proto_names/0 for a version that returns
%% the basenames sans extension
get_all_source_basenames() -> ["disconnect_reason.proto"].

%% Retrieve all proto file names, also imported ones.
%% The order is top-down. The first element is always the main
%% source file. The files are returned sans .proto extension,
%% to make it easier to use them with the various get_xyz_containment
%% functions.
get_all_proto_names() -> ["disconnect_reason"].

get_msg_containment("disconnect_reason") -> [];
get_msg_containment(P) -> error({gpb_error, {badproto, P}}).

get_pkg_containment("disconnect_reason") -> 'eventssidecar.v1';
get_pkg_containment(P) -> error({gpb_error, {badproto, P}}).

get_service_containment("disconnect_reason") -> [];
get_service_containment(P) -> error({gpb_error, {badproto, P}}).

get_rpc_containment("disconnect_reason") -> [];
get_rpc_containment(P) -> error({gpb_error, {badproto, P}}).

get_enum_containment("disconnect_reason") -> ['eventssidecar.v1.Reason'];
get_enum_containment(P) -> error({gpb_error, {badproto, P}}).

-spec get_proto_by_msg_name_as_fqbin(_) -> no_return().
get_proto_by_msg_name_as_fqbin(E) -> error({gpb_error, {badmsg, E}}).

-spec get_proto_by_service_name_as_fqbin(_) -> no_return().
get_proto_by_service_name_as_fqbin(E) -> error({gpb_error, {badservice, E}}).

get_proto_by_enum_name_as_fqbin(<<"eventssidecar.v1.Reason">>) -> "disconnect_reason";
get_proto_by_enum_name_as_fqbin(E) -> error({gpb_error, {badenum, E}}).

get_protos_by_pkg_name_as_fqbin(<<"eventssidecar.v1">>) -> ["disconnect_reason"];
get_protos_by_pkg_name_as_fqbin(E) -> error({gpb_error, {badpkg, E}}).

gpb_version_as_string() ->
    "4.20.0".

gpb_version_as_list() ->
    [4, 20, 0].

gpb_version_source() ->
    "file".