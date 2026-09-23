-module(vmq_connect_SUITE).

-compile(export_all).
-compile(nowarn_export_all).

%% ===================================================================
%% common_test callbacks
%% ===================================================================
init_per_suite(Config) ->
    cover:start(),
    [{ct_hooks, vmq_cth}|Config].

end_per_suite(_Config) ->
    _Config.

init_per_group(mqtts, Config) ->
    vmq_test_utils:setup(),
    Config1 = [{type, tcp},{port, 1889}, {address, "127.0.0.1"}|Config],
    start_listener(Config1);
init_per_group(mqttws, Config) ->
    vmq_test_utils:setup(),
    Config1 = [{type, ws},{port, 1890}, {address, "127.0.0.1"}|Config],
    start_listener(Config1);
init_per_group(mqttv4, Config) ->
    vmq_test_utils:setup(),
    Config1 = [{type, tcp},{port, 1888}, {address, "127.0.0.1"}|Config],
    [{protover, 4}|start_listener(Config1)];
init_per_group(mqttv5, Config) ->
    vmq_test_utils:setup(),
    Config1 = [{type, tcp},{port, 1887}, {address, "127.0.0.1"}|Config],
    [{protover, 5}|start_listener(Config1)].

end_per_group(_Group, Config) ->
    stop_listener(Config),
    vmq_test_utils:teardown(),
    ok.

init_per_testcase(_Case, Config) ->
    %% reset config before each test
    vmq_server_cmd:set_config(allow_anonymous, false),
    vmq_server_cmd:set_config(max_client_id_size, 23),
    vmq_config:configure_node(),
    Config.

end_per_testcase(_, Config) ->
    Config.

all() ->
    [
     {group, mqtts},
     {group, mqttws},
     {group, mqttv4},
     {group, mqttv5}
    ].

groups() ->
    Tests =
        [anon_denied_test,
         anon_success_test,
         invalid_id_0_test,
         invalid_id_0_311_test,
         invalid_id_missing_test,
         invalid_id_24_test,
         invalid_protonum_test,
         uname_no_password_denied_test,
         uname_password_denied_test,
         uname_password_success_test,
         change_subscriber_id_test
        ],
    RegisterFailedTests =
        [on_register_failed_no_hook_test,
         on_register_failed_auth_denied_test,
         on_register_failed_will_not_authorized_test
        ],
    [
     {mqttv4, [shuffle,sequence],
      [auth_on_register_change_username_test|Tests] ++ RegisterFailedTests},
     {mqtts, [], Tests},
     {mqttws, [], [ws_protocols_list_test, ws_no_known_protocols_test] ++ Tests},
     {mqttv5, [auth_on_register_change_username_test, uname_anon_username_test_m5]
      ++ RegisterFailedTests}
    ].

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% Actual Tests
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
anon_denied_test(Config) ->
    Connect = packet:gen_connect("connect-anon-test", [{keepalive,10}]),
    Connack = packet:gen_connack(5),
    {ok, Socket} = packet:do_client_connect(Connect, Connack, conn_opts(Config)),
    ok = close(Socket, Config).

anon_success_test(Config) ->
    vmq_server_cmd:set_config(allow_anonymous, true),
    vmq_config:configure_node(),
    %% allow_anonymous is proxied through vmq_config.erl
    Connect = packet:gen_connect("connect-success-test", [{keepalive,10}]),
    Connack = packet:gen_connack(0),
    {ok, Socket} = packet:do_client_connect(Connect, Connack, conn_opts(Config)),
    ok = close(Socket, Config).

uname_anon_username_test_m5(Config) ->
    vmq_server_cmd:set_config(allow_anonymous, true),
    vmq_config:configure_node(),
    Connect = mqtt5_v4compat:gen_connect(
        "set-username-test",
        [{keepalive, 10}, {username, "user"}, {password, "whatever"}],
        Config
    ),
    Connack = mqtt5_v4compat:gen_connack(success, Config),
    ok = vmq_plugin_mgr:enable_module_plugin(
        on_register_m5, ?MODULE, hook_on_register_uname_anon_username_m5, 5
    ),
    {ok, Socket} = mqtt5_v4compat:do_client_connect(Connect, Connack, conn_opts(Config), Config),
    ok = vmq_plugin_mgr:disable_module_plugin(
        on_register_m5, ?MODULE, hook_on_register_uname_anon_username_m5, 5
    ),
    ok = close(Socket, Config).

invalid_id_0_test(Config) ->
    Connect = packet:gen_connect(empty, [{keepalive,10}]),
    Connack = packet:gen_connack(2),
    {ok, Socket} = packet:do_client_connect(Connect, Connack, conn_opts(Config)),
    ok = close(Socket, Config).

invalid_id_0_311_test(Config) ->
    Connect = packet:gen_connect(empty, [{keepalive,10},{proto_ver,4}]),
    Connack = packet:gen_connack(0),
    ok = vmq_plugin_mgr:enable_module_plugin(
      auth_on_register, ?MODULE, hook_empty_client_id_proto_4, 6),
    {ok, Socket} = packet:do_client_connect(Connect, Connack, conn_opts(Config)),
    ok = vmq_plugin_mgr:disable_module_plugin(
      auth_on_register, ?MODULE, hook_empty_client_id_proto_4, 6),
    ok = close(Socket, Config).

invalid_id_missing_test(Config) ->
    Connect = packet:gen_connect(undefined, [{keepalive,10}]),
    {error, closed} = packet:do_client_connect(Connect, <<>>, conn_opts(Config)).

invalid_id_24_test(Config) ->
    Connect = packet:gen_connect("connect-invalid-id-test-", [{keepalive,10}]),
    Connack = packet:gen_connack(2), %% client id longer than 23 Characters
    {ok, Socket} = packet:do_client_connect(Connect, Connack, conn_opts(Config)),
    ok = close(Socket, Config).

invalid_protonum_test(Config) ->
    %% mosq_test.gen_connect("test", keepalive=10, proto_ver=0)
    Connect = <<16#10,16#12,16#00,16#06,16#4d,16#51,16#49,16#73,
                16#64,16#70,16#00,16#02,16#00,16#0a,16#00,16#04,
                16#74,16#65,16#73,16#74>>,
    Connack = packet:gen_connack(1),
    {ok, Socket} = packet:do_client_connect(Connect, Connack, conn_opts(Config)),
    ok = close(Socket, Config).

uname_no_password_denied_test(Config) ->
    Connect = packet:gen_connect("connect-uname-test-", [{keepalive,10}, {username, "user"}]),
    Connack = packet:gen_connack(4),
    ok = vmq_plugin_mgr:enable_module_plugin(
      auth_on_register, ?MODULE, hook_uname_no_password_denied, 6),
    {ok, Socket} = packet:do_client_connect(Connect, Connack, conn_opts(Config)),
    ok = vmq_plugin_mgr:disable_module_plugin(
      auth_on_register, ?MODULE, hook_uname_no_password_denied, 6),
    ok = close(Socket, Config).

uname_password_denied_test(Config) ->
    Connect = packet:gen_connect("connect-uname-pwd-test", [{keepalive,10}, {username, "user"},
                                                            {password, "password9"}]),
    Connack = packet:gen_connack(4),
    ok = vmq_plugin_mgr:enable_module_plugin(
      auth_on_register, ?MODULE, hook_uname_password_denied, 6),
    {ok, Socket} = packet:do_client_connect(Connect, Connack, conn_opts(Config)),
    ok = vmq_plugin_mgr:disable_module_plugin(
      auth_on_register, ?MODULE, hook_uname_password_denied, 6),
    ok = close(Socket, Config).

uname_password_success_test(Config) ->
    Connect = packet:gen_connect("connect-uname-pwd-test", [{keepalive,10}, {username, "user"},
                                                            {password, "password9"}]),
    Connack = packet:gen_connack(0),
    ok = vmq_plugin_mgr:enable_module_plugin(
      auth_on_register, ?MODULE, hook_uname_password_success, 6),
    {ok, Socket} = packet:do_client_connect(Connect, Connack, conn_opts(Config)),
    ok = vmq_plugin_mgr:disable_module_plugin(
      auth_on_register, ?MODULE, hook_uname_password_success, 6),
    ok = close(Socket, Config).

change_subscriber_id_test(Config) ->
    Connect = packet:gen_connect("change-sub-id-test",
                                 [{keepalive,10}, {username, "whatever"},
                                  {password, "whatever"}]),
    Connack = packet:gen_connack(0),
    ok = vmq_plugin_mgr:enable_module_plugin(
      auth_on_register, ?MODULE, hook_change_subscriber_id, 6),
    ok = vmq_plugin_mgr:enable_module_plugin(
      on_register, ?MODULE, hook_on_register_changed_subscriber_id, 5),
    {ok, Socket} = packet:do_client_connect(Connect, Connack, conn_opts(Config)),
    ok = vmq_plugin_mgr:disable_module_plugin(
      on_register, ?MODULE, hook_on_register_changed_subscriber_id, 5),
    ok = vmq_plugin_mgr:disable_module_plugin(
      auth_on_register, ?MODULE, hook_change_subscriber_id, 6),
    ok = close(Socket, Config).

auth_on_register_change_username_test(Config) ->
    Connect = mqtt5_v4compat:gen_connect("change-username-test",
                                         [{keepalive,10}, {username, "old_username"},
                                          {password, "whatever"}], Config),
    Connack = mqtt5_v4compat:gen_connack(success, Config),
    ok = vmq_plugin_mgr:enable_module_plugin(
      auth_on_register, ?MODULE, hook_change_username, 6),
    ok = vmq_plugin_mgr:enable_module_plugin(
      on_register, ?MODULE, hook_on_register_changed_username, 5),

    ok = vmq_plugin_mgr:enable_module_plugin(
      auth_on_register_m5, ?MODULE, hook_change_username_m5, 7),
    ok = vmq_plugin_mgr:enable_module_plugin(
      on_register_m5, ?MODULE, hook_on_register_changed_username_m5, 5),

    {ok, Socket} = mqtt5_v4compat:do_client_connect(Connect, Connack, conn_opts(Config), Config),

    ok = vmq_plugin_mgr:disable_module_plugin(
      auth_on_register_m5, ?MODULE, hook_change_username_m5, 7),
    ok = vmq_plugin_mgr:disable_module_plugin(
      on_register_m5, ?MODULE, hook_on_register_changed_username_m5, 5),

    ok = vmq_plugin_mgr:disable_module_plugin(
      on_register, ?MODULE, hook_on_register_changed_username, 5),
    ok = vmq_plugin_mgr:disable_module_plugin(
      auth_on_register, ?MODULE, hook_change_username, 6),
    ok = close(Socket, Config).

ws_protocols_list_test(Config) ->
    Connect = packet:gen_connect("ws_protocols_list_test", [{keepalive,10}]),
    Connack = packet:gen_connack(5),
    WSOpt  = {conn_opts, [{ws_protocols, ["foo", "mqtt", "bar"]}]},
    ConnOpts = [WSOpt | conn_opts(Config)],
    {ok, Socket} = packet:do_client_connect(Connect, Connack, ConnOpts),
    ok = close(Socket, Config).

ws_no_known_protocols_test(Config) ->
    Connect = packet:gen_connect("ws_no_known_protocols_test", [{keepalive,10}]),
    Connack = packet:gen_connack(5),
    WSOpt  = {conn_opts, [{ws_protocols, ["foo", "bar", "baz"]}]},
    ConnOpts = [WSOpt | conn_opts(Config)],
    {error, unknown_websocket_protocol} = packet:do_client_connect(Connect, Connack, ConnOpts),
    ok.

%% allow_anonymous is false and no auth_on_register hook is
%% registered, so the broker rejects the CONNECT itself
on_register_failed_no_hook_test(Config) ->
    ok = enable_register_failed_capture(),
    Connect = mqtt5_v4compat:gen_connect("orf-no-hook-test", [{keepalive,10}], Config),
    Connack = mqtt5_v4compat:gen_connack(auth_rejected(Config), Config),
    {ok, Socket} = mqtt5_v4compat:do_client_connect(Connect, Connack, conn_opts(Config), Config),
    {<<"orf-no-hook-test">>, no_matching_hook_found} = captured_register_failure(),
    ok = disable_register_failed_capture(),
    ok = close(Socket, Config).

on_register_failed_auth_denied_test(Config) ->
    {Hook, Fun, Arity} = auth_denied_hook(Config),
    ok = vmq_plugin_mgr:enable_module_plugin(Hook, ?MODULE, Fun, Arity),
    ok = enable_register_failed_capture(),
    Connect = mqtt5_v4compat:gen_connect("orf-auth-denied-test",
                                         [{keepalive,10}, {username, "user"},
                                          {password, "wrong"}], Config),
    Connack = mqtt5_v4compat:gen_connack(credentials_rejected(Config), Config),
    {ok, Socket} = mqtt5_v4compat:do_client_connect(Connect, Connack, conn_opts(Config), Config),
    {<<"orf-auth-denied-test">>, invalid_credentials} = captured_register_failure(),
    ok = disable_register_failed_capture(),
    ok = vmq_plugin_mgr:disable_module_plugin(Hook, ?MODULE, Fun, Arity),
    ok = close(Socket, Config).

%% the session registers and is then torn down because its last will
%% isn't authorized - no auth_on_publish hook grants the will topic
on_register_failed_will_not_authorized_test(Config) ->
    vmq_server_cmd:set_config(allow_anonymous, true),
    vmq_config:configure_node(),
    ok = enable_register_failed_capture(),
    Connect = mqtt5_v4compat:gen_connect("orf-will-test",
                                         [{keepalive,10}, {will_topic, "orf/will"},
                                          {will_msg, <<"goodbye">>}], Config),
    Connack = mqtt5_v4compat:gen_connack(not_authorized, Config),
    {ok, Socket} = mqtt5_v4compat:do_client_connect(Connect, Connack, conn_opts(Config), Config),
    {<<"orf-will-test">>, not_allowed} = captured_register_failure(),
    ok = disable_register_failed_capture(),
    ok = close(Socket, Config).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% Hooks
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
hook_empty_client_id_proto_4(_, _RandomId, _, _, _, _) -> ok.
hook_uname_no_password_denied(_, {"", <<"connect-uname-test-">>}, <<"user">>, undefined, _, _) -> {error, invalid_credentials}.
hook_uname_password_denied(_, {"", <<"connect-uname-pwd-test">>}, <<"user">>, <<"password9">>, _, _) -> {error, invalid_credentials}.
hook_uname_password_success(_, {"", <<"connect-uname-pwd-test">>}, <<"user">>, <<"password9">>, _, _) -> ok.
hook_change_subscriber_id(_, {"", <<"change-sub-id-test">>}, _, _, _, _) ->
    {ok, [{subscriber_id, {"newmp", <<"changed-client-id">>}}]}.
hook_on_register_changed_subscriber_id(_, {"newmp", <<"changed-client-id">>}, _, _, _) ->
    ok.

hook_change_username(_, _, <<"old_username">>, _, _, _) ->
    {ok, [{username, <<"new_username">>}]}.
hook_on_register_changed_username(_, _, <<"new_username">>, _, _) ->
    ok.

hook_change_username_m5(_, _, <<"old_username">>, _, _, _, _) ->
    {ok, #{username => <<"new_username">>}}.

hook_on_register_changed_username_m5(_,_, <<"new_username">>, _, _) ->
    ok.

hook_on_register_uname_anon_username_m5(_, _, <<"user">>, _, _) ->
    ok.

hook_orf_auth_denied(_, {"", <<"orf-auth-denied-test">>}, <<"user">>, <<"wrong">>, _, _) ->
    {error, invalid_credentials}.

hook_orf_auth_denied_m5(_, {"", <<"orf-auth-denied-test">>}, <<"user">>, <<"wrong">>, _, _, _) ->
    {error, invalid_credentials}.

hook_capture_register_failed(_Peer, {_MP, ClientId}, _UserName, _CleanSession, Reason) ->
    ets:insert(?MODULE, {register_failed, ClientId, Reason}),
    ok.

%% Helpers
enable_register_failed_capture() ->
    catch ets:delete(?MODULE),
    ?MODULE = ets:new(?MODULE, [public, named_table]),
    vmq_plugin_mgr:enable_module_plugin(
      on_register_failed, ?MODULE, hook_capture_register_failed, 5).

disable_register_failed_capture() ->
    ok = vmq_plugin_mgr:disable_module_plugin(
           on_register_failed, ?MODULE, hook_capture_register_failed, 5),
    true = ets:delete(?MODULE),
    ok.

captured_register_failure() ->
    [{register_failed, ClientId, Reason}] = ets:lookup(?MODULE, register_failed),
    {ClientId, Reason}.

%% the connack a broker side authentication rejection maps to
auth_rejected(Config) ->
    case mqtt5_v4compat:protover(Config) of
        4 -> not_authorized;
        5 -> bad_authn
    end.

%% the connack a rejection by the auth hook maps to
credentials_rejected(Config) ->
    case mqtt5_v4compat:protover(Config) of
        4 -> malformed_credentials;
        5 -> bad_authn
    end.

auth_denied_hook(Config) ->
    case mqtt5_v4compat:protover(Config) of
        4 -> {auth_on_register, hook_orf_auth_denied, 6};
        5 -> {auth_on_register_m5, hook_orf_auth_denied_m5, 7}
    end.

stop_listener(Config) ->
    Port = proplists:get_value(port, Config),
    Address = proplists:get_value(address, Config),
    vmq_server_cmd:listener_stop(Port, Address, false).


close(Socket, Config) ->
    (transport(Config)):close(Socket).

transport(Config) ->
    case lists:keyfind(type, 1, Config) of
        {type, tcp} ->
            gen_tcp;
        {type, ssl} ->
            ssl;
        {type, ws} ->
            gen_tcp
    end.

conn_opts(Config) ->
    {port, Port} = lists:keyfind(port, 1, Config),
    {address, Address} = lists:keyfind(address, 1, Config),
    {type, Type} = lists:keyfind(type, 1, Config),
    TransportOpts =
        case Type of
            tcp ->
                [{transport, gen_tcp}, {conn_opts, []}];
            ssl ->
                [{transport, ssl},
                 {conn_opts,
                  [
                   {cacerts, load_cacerts()}
                  ]}];
            ws ->
                [{transport, vmq_ws_transport}, {conn_opts, []}]
        end,
    [{port, Port},{hostname, Address},
     lists:keyfind(propver, 1, Config)|TransportOpts].

load_cacerts() ->
    IntermediateCA = ssl_path("test-signing-ca.crt"),
    RootCA = ssl_path("test-root-ca.crt"),
    load_cert(RootCA) ++ load_cert(IntermediateCA).

load_cert(Cert) ->
    {ok, Bin} = file:read_file(Cert),
    case filename:extension(Cert) of
        ".der" ->
            %% no decoding necessary
            [Bin];
        _ ->
            %% assume PEM otherwise
            Contents = public_key:pem_decode(Bin),
            [DER || {Type, DER, Cipher} <-
                    Contents, Type == 'Certificate',
                    Cipher == 'not_encrypted']
    end.

start_listener(Config) ->
    {port, Port} = lists:keyfind(port, 1, Config),
    {address, Address} = lists:keyfind(address, 1, Config),
    {type, Type} = lists:keyfind(type, 1, Config),
    ProtVers = {allowed_protocol_versions, "3,4,5"},

    Opts1 =
        case Type of
            ssl ->
                [{ssl, true},
                 {nr_of_acceptors, 5},
                 {cafile, ssl_path("all-ca.crt")},
                 {certfile, ssl_path("server.crt")},
                 {keyfile, ssl_path("server.key")},
                 {tls_version, "tlsv1.2"}];
            tcp ->
                [];
            ws ->
                [{websocket,true}]
        end,
    {ok, _} = vmq_server_cmd:listener_start(Port, Address, [ProtVers | Opts1]),
    [{address, Address},{port, Port},{opts, Opts1}|Config].

ssl_path(File) ->
    Path = filename:dirname(
             proplists:get_value(source, ?MODULE:module_info(compile))),
    filename:join([Path, "ssl", File]).
