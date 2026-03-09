-module(vmq_redis_cli).
-export([register_cli/0]).
-behaviour(clique_handler).

register_cli() ->
    clique:register_usage(["vmq-admin", "redis"], redis_usage()),
    clique:register_usage(["vmq-admin", "redis", "show"], redis_show_usage()),
    redis_show_cmd().

redis_usage() ->
    [
        "vmq-admin redis <sub-command>\n\n",
        "  Manage Redis-backed runtime controls.\n\n",
        "  Sub-commands:\n",
        "    show                Show Redis configuration\n",
        "  Use --help after a sub-command for more details.\n"
    ].

redis_show_cmd() ->
    Cmd = ["vmq-admin", "redis", "show"],
    Callback = fun(_, _, _) ->
        RedisEnabled = application:get_env(vmq_server, redis_enabled, true),
        ActiveBackend = vmq_redis_backend:backend(),
        [
            clique_status:table([
                [
                    {'redis_enabled', RedisEnabled},
                    {'active_backend', ActiveBackend}
                ]
            ])
        ]
    end,
    clique:register_command(Cmd, [], [], Callback).

redis_show_usage() ->
    [
        "vmq-admin redis show\n\n",
        "  Shows the current state of Redis configuration.\n\n"
    ].
