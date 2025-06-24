-module(vmq_http_SUITE).
-export([
         init_per_suite/1,
         end_per_suite/1,
         init_per_testcase/2,
         end_per_testcase/2,
         all/0
        ]).

-export([
          simple_healthcheck_test/1,
          ok_redis_healthcheck_test/1,
          down_redis_healthcheck_test/1
        ]).

init_per_suite(_Config) ->
    cover:start(),
    _Config.

end_per_suite(_Config) ->
    _Config.

init_per_testcase(_Case, Config) ->
    vmq_test_utils:setup(),
    vmq_server_cmd:set_config(allow_anonymous, true),
    Config.

end_per_testcase(_, Config) ->
    vmq_test_utils:teardown(),
    Config.

all() ->
    [
        simple_healthcheck_test, 
        ok_redis_healthcheck_test, 
        down_redis_healthcheck_test
    ].

simple_healthcheck_test(_) ->
    %% we have to setup the listener here, because vmq_test_utils is overriding
    %% the default set in vmq_server.app.src
    vmq_server_cmd:listener_start(8888, [{http, true},
                                         {config_mod, vmq_health_http},
                                         {config_fun, routes}]),
    application:ensure_all_started(inets),
    {ok, {_Status, _Headers, Body}} = httpc:request("http://localhost:8888/health"),
    JsonResponse = jsx:decode(list_to_binary(Body), [return_maps, {labels, binary}]),
    <<"OK">> = maps:get(<<"status">>, JsonResponse).

ok_redis_healthcheck_test(_) ->
    %% Setup the listener for the test
    vmq_server_cmd:listener_start(8889, [{http, true},
                                         {config_mod, vmq_health_http},
                                         {config_fun, routes}]),
    application:ensure_all_started(inets),
    % Redis should be available: expect "OK"
    {ok, {_Status, _Headers, Body}} = httpc:request("http://localhost:8889/redis-health"),
    JsonResponse = jsx:decode(list_to_binary(Body), [return_maps, {labels, binary}]),
    <<"OK">> = maps:get(<<"status">>, JsonResponse).

down_redis_healthcheck_test(_) ->
    %% Setup the listener for the test
    vmq_server_cmd:listener_start(8890, [{http, true},
                                         {config_mod, vmq_health_http},
                                         {config_fun, routes}]),
    application:ensure_all_started(inets),
    % Set Redis endpoint to an unreachable address to simulate down
    application:set_env(vmq_server, redis_sentinel_endpoints, "[{\"127.0.0.1111\", 26379}]"),
    supervisor:terminate_child(vmq_server_sup, eredis),
    timer:sleep(4000),
    {ok, {_Status, _Headers, Body}} = httpc:request("http://localhost:8890/redis-health"),
    JsonResponse = jsx:decode(list_to_binary(Body), [return_maps, {labels, binary}]),
    application:set_env(vmq_server, redis_sentinel_endpoints, "[{\"127.0.0.1\", 26379}]"),
    <<"DOWN">> = maps:get(<<"status">>, JsonResponse).
