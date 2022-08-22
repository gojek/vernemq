%% Copyright 2018 Erlio GmbH Basel Switzerland (http://erl.io)
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.

-module(vmq_gojek_auth).
-behaviour(auth_on_register_hook).
-behaviour(auth_on_subscribe_hook).
-behaviour(auth_on_publish_hook).
-behaviour(auth_on_subscribe_m5_hook).
-behaviour(auth_on_publish_m5_hook).
-behaviour(on_config_change_hook).

-export([start/0,
         stop/0,
         init/0,
         load_from_file/1,
         load_from_list/1,
         check/4]).

-export([auth_on_subscribe/3,
         auth_on_publish/6,
         auth_on_subscribe_m5/4,
         auth_on_publish_m5/7,
         auth_on_register/5,
         change_config/1]).

-import(vmq_topic, [words/1, match/2]).

-define(INIT_ACL, {[],[],[],[],[],[]}).
-define(TABLES, [
                 vmq_gojek_auth_acl_read_pattern,
                 vmq_gojek_auth_acl_write_pattern,
                 vmq_gojek_auth_acl_read_all,
                 vmq_gojek_auth_acl_write_all,
                 vmq_gojek_auth_acl_read_user,
                 vmq_gojek_auth_acl_write_user
                ]).
-define(TABLE_OPTS, [public, named_table, {read_concurrency, true}]).
-define(USER_SUP, <<"%u">>).
-define(CLIENT_SUP, <<"%c">>).
-define(MOUNTPOINT_SUP, <<"%m">>).
-define(PROFILE_ID_SUP, <<"%p">>).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-define(setup(F), {setup, fun setup/0, fun teardown/1, F}).
-endif.

-define(SecretKey, application:get_env(vmq_gojek_auth, secret_key, undefined)).
-define(EnableAuthOnRegister, application:get_env(vmq_gojek_auth, enable_jwt_auth, false)).
-define(EnableAclHooks, application:get_env(vmq_gojek_auth, enable_acl_hooks, false)).
-define(RegView, application:get_env(vmq_server, default_reg_view, vmq_reg_trie)).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% Plugin Callbacks
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
start() ->
    {ok, _} = application:ensure_all_started(vmq_gojek_auth),
  vmq_gojek_auth_cli:register(),
    ok.

stop() ->
    application:stop(vmq_gojek_auth).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% Hooks
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
change_config(Configs) ->
    case lists:keyfind(vmq_gojek_auth, 1, Configs) of
        false ->
            ok;
        _ ->
            vmq_gojek_auth_reloader:change_config_now()
    end.

auth_on_subscribe(User, SubscriberId, TopicList) ->
    auth_on_subscribe(User, SubscriberId, TopicList, []).

auth_on_subscribe(_, _, [], Modifiers) -> {ok, lists:reverse(Modifiers)};
auth_on_subscribe(User, SubscriberId, TopicList, Modifiers) ->
    auth_on_subscribe(?RegView, User, SubscriberId, TopicList, Modifiers).

auth_on_subscribe(RegView, User, SubscriberId, [{Topic, Qos} | Rest], Modifiers) ->
    D = is_topic_invalid(RegView, Topic) orelse is_acl_auth_disabled(),
    if D ->
        next;
      true ->
          case check(read, Topic, User, SubscriberId) of
            true ->
              auth_on_subscribe(User, SubscriberId, Rest, [{Topic, Qos} | Modifiers]);
            false ->
              ModTopic = {Topic, not_allowed},
              auth_on_subscribe(User, SubscriberId, Rest, [ModTopic | Modifiers])
          end
    end.

auth_on_publish(User, SubscriberId, _, Topic, _, _) ->
  D = is_acl_auth_disabled(),
  if D ->
        next;
     true ->
          case check(write, Topic, User, SubscriberId) of
              true ->
                  ok;
              false ->
                  next
          end
  end.

auth_on_subscribe_m5(_, _, []) -> ok;
auth_on_subscribe_m5(User, SubscriberId, [{Topic, _Qos}|Rest]) ->
    case check(read, Topic, User, SubscriberId) of
      true ->
        auth_on_subscribe(User, SubscriberId, Rest);
      false ->
        next
    end.
auth_on_subscribe_m5(User, SubscriberId, Topics, _Props) ->
    auth_on_subscribe_m5(User, SubscriberId, Topics).

auth_on_publish_m5(User, SubscriberId, QoS, Topic, Payload, IsRetain, _Props) ->
    auth_on_publish(User, SubscriberId, QoS, Topic, Payload, IsRetain).

auth_on_register({_IpAddr, _Port} = Peer, {_MountPoint, _ClientId} = SubscriberId, UserName, Password, CleanSession) ->
  %% do whatever you like with the params, all that matters
  %% is the return value of this function
  %%
  %% 1. return 'ok' -> CONNECT is authenticated
  %% 2. return 'next' -> leave it to other plugins to decide
  %% 3. return {ok, [{ModifierKey, NewVal}...]} -> CONNECT is authenticated, but we might want to set some options used throughout the client session:
  %%      - {mountpoint, NewMountPoint::string}
  %%      - {clean_session, NewCleanSession::boolean}
  %% 4. return {error, invalid_credentials} -> CONNACK_CREDENTIALS is sent
  %% 5. return {error, whatever} -> CONNACK_AUTH is sent

  %% we return 'ok'
  D = is_auth_on_register_disabled(),
  if D ->
        next;
    true ->
        {Result, Claims} = verify(Password, ?SecretKey),
        if
          Result =:= ok -> check_rid(Claims, UserName);
        %else block
          true -> {error, invalid_signature}
        end
  end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% Internal+
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
init() ->
    lists:foreach(fun(T) ->
                          case lists:member(T, ets:all()) of
                              true -> ok;
                              false ->
                                  ets:new(T, ?TABLE_OPTS)
                          end
                  end, ?TABLES).

load_from_file(File) ->
    case file:open(File, [read, binary]) of
        {ok, Fd} ->
            F = fun(FF, read) -> {FF, rl(Fd)};
                   (_, close) -> file:close(Fd)
                end,
            age_entries(),
            parse_acl_line(F(F,read), all),
            del_aged_entries();
        {error, Reason} ->
            error_logger:error_msg("can't load acl file ~p due to ~p", [File, Reason]),
            ok
    end.

load_from_list(List) ->
    put(vmq_acl_list, List),
    F = fun(FF, read) ->
                case get(vmq_acl_list) of
                    [I|Rest] ->
                        put(vmq_acl_list, Rest),
                        {FF, I};
                    [] ->
                        {FF, eof}
                end;
           (_, close) ->
                put(vmq_acl_list, undefined),
                ok
        end,
    age_entries(),
    parse_acl_line(F(F, read), all),
    del_aged_entries().

parse_acl_line({F, <<"#", _/binary>>}, User) ->
    %% comment
    parse_acl_line(F(F,read), User);
parse_acl_line({F, <<"topic read ", Topic/binary>>}, User) ->
    in(read, User, Topic),
    parse_acl_line(F(F,read), User);
parse_acl_line({F, <<"topic write ", Topic/binary>>}, User) ->
    in(write, User, Topic),
    parse_acl_line(F(F,read), User);
parse_acl_line({F, <<"topic ", Topic/binary>>}, User) ->
    in(read, User, Topic),
    in(write, User, Topic),
    parse_acl_line(F(F,read), User);
parse_acl_line({F, <<"user ", User/binary>>}, _) ->
    UserLen = byte_size(User) -1,
    <<SUser:UserLen/binary, _/binary>> = User,
    parse_acl_line(F(F,read), SUser);
parse_acl_line({F, <<"pattern read ", Topic/binary>>}, User) ->
    in(read, pattern, Topic),
    parse_acl_line(F(F,read), User);
parse_acl_line({F, <<"pattern write ", Topic/binary>>}, User) ->
    in(write, pattern, Topic),
    parse_acl_line(F(F,read), User);
parse_acl_line({F, <<"pattern ", Topic/binary>>}, User) ->
    in(read, pattern, Topic),
    in(write, pattern, Topic),
    parse_acl_line(F(F,read), User);
parse_acl_line({F, <<"\n">>}, User) ->
    parse_acl_line(F(F,read), User);
parse_acl_line({F, eof}, _User) ->
    F(F,close),
    ok.

check(Type, [Word|_] = Topic, User, SubscriberId) when is_binary(Word) ->
    case check_all_acl(Type, Topic) of
        true -> true;
        false when User == all -> false;
        false ->
            case check_user_acl(Type, User, Topic) of
                true -> true;
                false -> check_pattern_acl(Type, Topic, User, SubscriberId)
            end
    end.

check_all_acl(Type, TIn) ->
    {Tbl, _} = t(Type, all, TIn),
    iterate_until_true(Tbl, fun(T) -> match(TIn, T) end).

check_user_acl(Type, User, TIn) ->
    {Tbl, _} = t(Type, User, TIn),
    iterate_until_true(ets:match(Tbl, {{User, '$1'}, '_'}),
                      fun([T]) -> match(TIn, T) end).

check_pattern_acl(Type, TIn, User, SubscriberId) ->
    {Tbl, _} = t(Type, pattern, TIn),
    iterate_until_true(Tbl, fun(P) ->
                                    T = topic(User, SubscriberId, P),
                                    match(TIn, T)
                            end).

topic(User, {MP, ClientId}, Topic) ->
    subst(list_to_binary(MP), User, ClientId, Topic, []).

subst(MP, User, ClientId, [U|Rest], Acc) when U == ?USER_SUP ->
    subst(MP, User, ClientId, Rest, [User|Acc]);
subst(MP, User, ClientId, [C|Rest], Acc) when C == ?CLIENT_SUP ->
    subst(MP, User, ClientId, Rest, [ClientId|Acc]);
subst(MP, User, ClientId, [M|Rest], Acc) when M == ?MOUNTPOINT_SUP ->
    subst(MP, User, ClientId, Rest, [MP|Acc]);
subst(MP, User, ClientID, [P|Rest], Acc) when P == ?PROFILE_ID_SUP ->
    subst(MP, User, ClientID, Rest, [get_profile_id(ClientID)|Acc]);
subst(MP, User, ClientId, [W|Rest], Acc) ->
    subst(MP, User, ClientId, Rest, [W|Acc]);
subst(_, _, _, [], Acc) -> lists:reverse(Acc).

in(Type, User, Topic) when is_binary(Topic) ->
    TopicLen = byte_size(Topic) -1,
    <<STopic:TopicLen/binary, _/binary>> = Topic,
    case validate(STopic) of
        {ok, Words} ->
            {Tbl, Obj} = t(Type, User, Words),
            ets:insert(Tbl, Obj);
        {error, Reason} ->
            error_logger:warning_msg("can't validate ~p acl topic ~p for user ~p due to ~p", [Type, STopic, User, Reason])
    end.

validate(Topic) ->
    vmq_topic:validate_topic(subscribe, Topic).

t(read, all, Topic) -> {vmq_gojek_auth_acl_read_all, {Topic, 1}};
t(write, all, Topic) ->  {vmq_gojek_auth_acl_write_all, {Topic, 1}};
t(read, pattern, Topic) ->  {vmq_gojek_auth_acl_read_pattern, {Topic, 1}};
t(write, pattern, Topic) -> {vmq_gojek_auth_acl_write_pattern, {Topic, 1}};
t(read, User, Topic) -> {vmq_gojek_auth_acl_read_user, {{User, Topic}, 1}};
t(write, User, Topic) -> {vmq_gojek_auth_acl_write_user, {{User, Topic}, 1}}.

iterate_until_true(T, Fun) when is_atom(T) ->
    iterate_ets_until_true(T, ets:first(T), Fun);
iterate_until_true(T, Fun) when is_list(T) ->
    iterate_list_until_true(T, Fun).

iterate_ets_until_true(_, '$end_of_table', _) -> false;
iterate_ets_until_true(Table, K, Fun) ->
    case Fun(K) of
        true -> true;
        false ->
            iterate_ets_until_true(Table, ets:next(Table, K), Fun)
    end.

iterate_list_until_true([], _) -> false;
iterate_list_until_true([T|Rest], Fun) ->
    case Fun(T) of
        true -> true;
        false ->
            iterate_list_until_true(Rest, Fun)
    end.

rl({ok, Data}) -> Data;
rl({error, Reason}) -> exit(Reason);
rl(eof) -> eof;
rl(Fd) ->
    rl(file:read_line(Fd)).


age_entries() ->
    lists:foreach(fun age_entries/1, ?TABLES).
age_entries(T) ->
    iterate(T, fun(K) -> ets:update_element(T, K, {2,2}) end).

del_aged_entries() ->
    lists:foreach(fun del_aged_entries/1, ?TABLES).
del_aged_entries(T) ->
    ets:match_delete(T, {'_', 2}).

iterate(T, Fun) ->
    iterate(T, Fun, ets:first(T)).
iterate(_, _, '$end_of_table') -> ok;
iterate(T, Fun, K) ->
    Fun(K),
    iterate(T, Fun, ets:next(T, K)).

is_auth_on_register_disabled() ->
  E = ?EnableAuthOnRegister,
  if
    E == true -> false;
    true -> true
  end.

is_acl_auth_disabled() ->
  E = ?EnableAclHooks,
  if
    E == true -> false;
    true -> true
  end.

is_topic_invalid(vmq_reg_redis_trie, Topic) ->
    case vmq_topic:contains_wildcard(Topic) of
        true ->
            not is_complex_topic_whitelisted(Topic);
        _ -> false
    end;
is_topic_invalid(_, _) -> false.

is_complex_topic_whitelisted([<<"$share">>, _Group | Topic]) -> is_complex_topic_whitelisted(Topic);
is_complex_topic_whitelisted([<<"$share">> | _] = _Topic) -> false;
is_complex_topic_whitelisted(Topic) ->
    MPTopic = {"", Topic},
    case ets:lookup(vmq_redis_trie_node, MPTopic) of
        [_] ->
            true;
        _ ->
            false
    end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% Helpers for jwt authentication
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
verify(Password, SecretKey) ->
  try jwerl:verify(Password, hs256, SecretKey) of
    _ -> jwerl:verify(Password, hs256, SecretKey)
  catch
    error:Error -> {error, invalid_signature}
  end.

check_rid(Claims, UserName) ->
  case maps:find(rid, Claims) of
    {ok, Value} ->
      if Value =:= UserName -> ok;
      %else block
        true -> error
      end;
    error -> error
  end.

get_profile_id(ClientID) ->
  io:format(string:nth_lexeme(ClientID, 2, ":")),
  string:nth_lexeme(ClientID, 3, ":").

-ifdef(TEST).
%%%%%%%%%%%%%
%%% Tests
%%%%%%%%%%%%%

acl_test_() ->
    [
     {"Simple ACL Test - vmq_reg_trie",
      ?setup(fun simple_acl/1)},
     {"Simple ACL Test - vmq_reg_redis_trie",
         {setup, fun setup_vmq_reg_redis_trie/0, fun teardown/1, fun simple_acl/1}}
    ].

setup() -> ok = application:set_env(vmq_gojek_auth, enable_acl_hooks, true), init().
setup_vmq_reg_redis_trie() ->
    ok = application:set_env(vmq_gojek_auth, enable_acl_hooks, true),
    ok = application:set_env(vmq_server, default_reg_view, vmq_reg_redis_trie),
    init(),
    ets:new(vmq_redis_trie_node, [{keypos, 2}|?TABLE_OPTS]),
    ets:insert(vmq_redis_trie_node, {trie_node, {"", [<<"x">>, <<"y">>, <<"z">>, <<"#">>]}, [<<"x">>, <<"y">>, <<"z">>, <<"#">>]}),
    vmq_reg_redis_trie.
teardown(RegView) ->
    case RegView of
        vmq_reg_redis_trie -> ets:delete(vmq_redis_trie_node);
        _ -> ok
    end,
    ets:delete(vmq_gojek_auth_acl_read_all),
    ets:delete(vmq_gojek_auth_acl_write_all),
    ets:delete(vmq_gojek_auth_acl_read_user),
    ets:delete(vmq_gojek_auth_acl_write_user),
    application:unset_env(vmq_gojek_auth, enable_acl_hooks),
    application:unset_env(vmq_server, default_reg_view).

simple_acl(_) ->
    ACL = [<<"# simple comment\n">>,
           <<"topic read a/b/c\n">>,
           <<"# other comment \n">>,
           <<"topic write a/b/c\n">>,
           <<"\n">>,
           <<"# ACL for user 'test'\n">>,
           <<"user test\n">>,
           <<"topic x/y/z/#\n">>,
           <<"# some patterns\n">>,
           <<"pattern read %m/%u/%c\n">>,
           <<"pattern read example/%p\n">>,
           <<"pattern write %m/%u/%c\n">>
          ],
    load_from_list(ACL),
    [ ?_assertEqual([[{[<<"a">>, <<"b">>, <<"c">>], 1}]], ets:match(vmq_gojek_auth_acl_read_all, '$1'))
    , ?_assertEqual([[{[<<"a">>, <<"b">>, <<"c">>], 1}]], ets:match(vmq_gojek_auth_acl_write_all, '$1'))
    , ?_assertEqual([[{{<<"test">>, [<<"x">>, <<"y">>, <<"z">>, <<"#">>]}, 1}]], ets:match(vmq_gojek_auth_acl_read_user, '$1'))
    , ?_assertEqual([[{{<<"test">>, [<<"x">>, <<"y">>, <<"z">>, <<"#">>]}, 1}]], ets:match(vmq_gojek_auth_acl_write_user, '$1'))
    , ?_assertEqual([[{[<<"%m">>, <<"%u">>, <<"%c">>], 1}],  [{[<<"example">>,<<"%p">>],1}]], ets:match(vmq_gojek_auth_acl_read_pattern, '$1'))
    , ?_assertEqual([[{[<<"%m">>, <<"%u">>, <<"%c">>], 1}]], ets:match(vmq_gojek_auth_acl_write_pattern, '$1'))
    %% positive auth_on_subscribe
    , ?_assertEqual({ok,[{[<<"a">>,<<"b">>,<<"c">>],0},
                          {[<<"x">>,<<"y">>,<<"z">>,<<"#">>],0},
                          {[<<>>,<<"test">>,<<"my-client-id">>],0}]},
                          auth_on_subscribe(<<"test">>, {"", <<"my-client-id">>},
                                          [{[<<"a">>, <<"b">>, <<"c">>], 0}
                                           ,{[<<"x">>, <<"y">>, <<"z">>, <<"#">>], 0}
                                           ,{[<<"">>, <<"test">>, <<"my-client-id">>], 0}]))
      , ?_assertEqual({ok,[{[<<"a">>,<<"b">>,<<"c">>],0},
                      {[<<"x">>,<<"y">>,<<"z">>,<<"#">>],0},
                      {[<<"example">>,<<"profile-id">>],0}]}
                      , auth_on_subscribe(<<"test">>, {"", <<"device-id:owner-id:profile-id">>},
                        [{[<<"a">>, <<"b">>, <<"c">>], 0}
                          ,{[<<"x">>, <<"y">>, <<"z">>, <<"#">>], 0}
                          ,{[<<"example">>, <<"profile-id">>], 0}]))
      ,
      %% colon separated username
      ?_assertEqual({ok,[{[<<"a">>,<<"b">>,<<"c">>],0},
                        {[<<"x">>,<<"y">>,<<"z">>,<<"#">>],0},
                        {[<<>>,<<"test">>,<<"my-client-id">>],0}]},
                      auth_on_subscribe(<<"test">>, {"", <<"my-client-id">>},
                      [{[<<"a">>, <<"b">>, <<"c">>], 0}
                        ,{[<<"x">>, <<"y">>, <<"z">>, <<"#">>], 0}
                        ,{[<<"">>, <<"test">>, <<"my-client-id">>], 0}]))
    , ?_assertEqual({ok,[{[<<"a">>,<<"b">>,<<"c">>],0},
                        {[<<"x">>,<<"y">>,<<"z">>,<<"#">>],not_allowed},
                        {[<<>>,<<"test">>,<<"my-client-id">>],not_allowed}]},
                        auth_on_subscribe(<<"invalid-user">>, {"", <<"my-client-id">>},
                                          [{[<<"a">>, <<"b">>, <<"c">>], 0}
                                           ,{[<<"x">>, <<"y">>, <<"z">>, <<"#">>], 0}
                                           ,{[<<"">>, <<"test">>, <<"my-client-id">>], 0}]))
    , ?_assertEqual(ok, auth_on_publish(<<"test">>, {"", <<"my-client-id">>}, 1,
                                          [<<"a">>, <<"b">>, <<"c">>], <<"payload">>, false))
    , ?_assertEqual(ok, auth_on_publish(<<"test">>, {"", <<"my-client-id">>}, 1,
                                          [<<"x">>, <<"y">>, <<"z">>, <<"blabla">>], <<"payload">>, false))
    , ?_assertEqual(ok, auth_on_publish(<<"test">>, {"", <<"my-client-id">>}, 1,
                                          [<<"">>, <<"test">>, <<"my-client-id">>], <<"payload">>, false))
    , ?_assertEqual(next, auth_on_publish(<<"invalid-user">>, {"", <<"my-client-id">>}, 1,
                                          [<<"x">>, <<"y">>, <<"z">>, <<"blabla">>], <<"payload">>, false))
    , ?_assertEqual(next, auth_on_publish(<<"invalid-user">>, {"", <<"my-client-id">>}, 1,
                                          [<<"">>, <<"test">>, <<"my-client-id">>], <<"payload">>, false))
    ].
-endif.
