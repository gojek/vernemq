%% -*- coding: utf-8 -*-
%% Automatically generated, do not edit
%% Generated by gpb_compile version 4.19.1

-ifndef(on_unsubscribe_pb).
-define(on_unsubscribe_pb, true).

-define(on_unsubscribe_pb_gpb_version, "4.19.1").

-ifndef('EVENTSSIDECAR.V1.ONUNSUBSCRIBE_PB_H').
-define('EVENTSSIDECAR.V1.ONUNSUBSCRIBE_PB_H', true).
-record('eventssidecar.v1.OnUnsubscribe',
        {timestamp = undefined  :: on_unsubscribe_pb:'google.protobuf.Timestamp'() | undefined, % = 1, optional
         username = <<>>        :: unicode:chardata() | undefined, % = 2, optional
         client_id = <<>>       :: unicode:chardata() | undefined, % = 3, optional
         mountpoint = <<>>      :: unicode:chardata() | undefined, % = 4, optional
         topics = []            :: [unicode:chardata()] | undefined % = 5, repeated
        }).
-endif.

-ifndef('GOOGLE.PROTOBUF.TIMESTAMP_PB_H').
-define('GOOGLE.PROTOBUF.TIMESTAMP_PB_H', true).
-record('google.protobuf.Timestamp',
        {seconds = 0            :: integer() | undefined, % = 1, optional, 64 bits
         nanos = 0              :: integer() | undefined % = 2, optional, 32 bits
        }).
-endif.

-endif.