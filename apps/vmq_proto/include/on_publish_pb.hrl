%% -*- coding: utf-8 -*-
%% Automatically generated, do not edit
%% Generated by gpb_compile version 4.20.0

-ifndef(on_publish_pb).
-define(on_publish_pb, true).

-define(on_publish_pb_gpb_version, "4.20.0").

-ifndef('EVENTSSIDECAR.V1.ONPUBLISH_PB_H').
-define('EVENTSSIDECAR.V1.ONPUBLISH_PB_H', true).
-record('eventssidecar.v1.OnPublish',
    % = 1, optional
    {
        timestamp = undefined :: on_publish_pb:'google.protobuf.Timestamp'() | undefined,
        % = 2, optional
        username = <<>> :: unicode:chardata() | undefined,
        % = 3, optional
        client_id = <<>> :: unicode:chardata() | undefined,
        % = 4, optional
        mountpoint = <<>> :: unicode:chardata() | undefined,
        % = 5, optional, 32 bits
        qos = 0 :: integer() | undefined,
        % = 6, optional
        topic = <<>> :: unicode:chardata() | undefined,
        % = 7, optional
        payload = <<>> :: iodata() | undefined,
        % = 8, optional
        retain = false :: boolean() | 0 | 1 | undefined,
        % = 9, repeated
        matched_acl = [] :: [on_publish_pb:'eventssidecar.v1.MatchedAcl'()] | undefined
    }
).
-endif.

-ifndef('EVENTSSIDECAR.V1.MATCHEDACL_PB_H').
-define('EVENTSSIDECAR.V1.MATCHEDACL_PB_H', true).
-record('eventssidecar.v1.MatchedAcl',
    % = 1, optional
    {
        label = <<>> :: unicode:chardata() | undefined,
        % = 2, optional
        pattern = <<>> :: unicode:chardata() | undefined
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

-endif.
