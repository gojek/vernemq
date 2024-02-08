%% -*- coding: utf-8 -*-
%% Automatically generated, do not edit
%% Generated by gpb_compile version 4.20.0

-ifndef(on_delivery_complete_pb).
-define(on_delivery_complete_pb, true).

-define(on_delivery_complete_pb_gpb_version, "4.20.0").

-ifndef('EVENTSSIDECAR.V1.ONDELIVERYCOMPLETE_PB_H').
-define('EVENTSSIDECAR.V1.ONDELIVERYCOMPLETE_PB_H', true).
-record('eventssidecar.v1.OnDeliveryComplete',
    % = 1, optional
    {
        timestamp = undefined :: on_delivery_complete_pb:'google.protobuf.Timestamp'() | undefined,
        % = 2, optional
        username = <<>> :: unicode:chardata() | undefined,
        % = 3, optional
        client_id = <<>> :: unicode:chardata() | undefined,
        % = 4, optional
        mountpoint = <<>> :: unicode:chardata() | undefined,
        % = 5, optional
        topic = <<>> :: unicode:chardata() | undefined,
        % = 6, optional, 32 bits
        qos = 0 :: integer() | undefined,
        % = 7, optional
        is_retain = false :: boolean() | 0 | 1 | undefined,
        % = 8, optional
        payload = <<>> :: iodata() | undefined,
        % = 9, optional
        matched_acl = undefined ::
            on_delivery_complete_pb:'eventssidecar.v1.MatchedACL'() | undefined
    }
).
-endif.

-ifndef('GOOGLE.PROTOBUF.TIMESTAMP_PB_H').
-define('GOOGLE.PROTOBUF.TIMESTAMP_PB_H', true).
-record('google.protobuf.Timestamp',
    % = 1, optional, 64 bits
    {
        seconds = 0 :: integer() | undefined,
        % = 2, optional, 32 bits
        nanos = 0 :: integer() | undefined
    }
).
-endif.

-ifndef('EVENTSSIDECAR.V1.MATCHEDACL_PB_H').
-define('EVENTSSIDECAR.V1.MATCHEDACL_PB_H', true).
-record('eventssidecar.v1.MatchedACL',
    % = 1, optional
    {
        name = <<>> :: unicode:chardata() | undefined,
        % = 2, optional
        pattern = <<>> :: unicode:chardata() | undefined
    }
).
-endif.

-endif.
