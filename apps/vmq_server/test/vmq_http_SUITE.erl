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
          redis_healthcheck_test/1
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
    [simple_healthcheck_test, redis_healthcheck_test].

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

redis_healthcheck_test(_) ->
    %% Setup the listener for the test
    vmq_server_cmd:listener_start(8889, [{http, true},
                                         {config_mod, vmq_health_http},
                                         {config_fun, routes}]),
    application:ensure_all_started(inets),

    % 1. Redis should be available: expect "OK"
    {ok, {_Status1, _Headers1, Body1}} = httpc:request("http://localhost:8889/redis-health"),
    JsonResponse1 = jsx:decode(list_to_binary(Body1), [return_maps, {labels, binary}]),
    <<"OK">> = maps:get(<<"status">>, JsonResponse1),

    % 2. Simulate Redis unavailable: stop Redis depending on environment
    CI = os:getenv("CI"),
    OS = os:type(),
    _ = case CI of
        "true" ->
            % GitHub Actions: stop Docker container
            os:cmd("docker stop $(docker ps --filter 'name=redissentinel' --format '{{.Names}}')");
        _ ->
            case OS of
                {unix, darwin} ->
                    os:cmd("brew services stop redis");
                {unix, linux} ->
                    os:cmd("sudo systemctl stop redis-server");
                _ ->
                    ok
            end
    end,
    timer:sleep(7000),

    {ok, {_Status2, _Headers2, Body2}} = httpc:request("http://localhost:8889/redis-health"),
    JsonResponse2 = jsx:decode(list_to_binary(Body2), [return_maps, {labels, binary}]),

    % 3. Start Redis again
    _ = case CI of
        "true" ->
            os:cmd("docker start $(docker ps -a --filter 'name=redissentinel' --format '{{.Names}}')");
        _ ->
            case OS of
                {unix, darwin} ->
                    os:cmd("brew services start redis");
                {unix, linux} ->
                    os:cmd("sudo systemctl start redis-server");
                _ ->
                    ok
            end
    end,

    <<"DOWN">> = maps:get(<<"status">>, JsonResponse2).
