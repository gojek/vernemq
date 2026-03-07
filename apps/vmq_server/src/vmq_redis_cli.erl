-module(vmq_redis_cli).
-export([register_cli/0]).
-behaviour(clique_handler).

register_cli() ->
    clique:register_usage(["vmq-admin", "redis"], redis_usage()),
    clique:register_usage(["vmq-admin", "redis", "show"], redis_show_usage()),
    clique:register_usage(["vmq-admin", "redis", "poll-main-queue"], redis_main_queue_poll_usage()),
    clique:register_usage(
        ["vmq-admin", "redis", "poll-main-queue", "enable"],
        redis_main_queue_poll_enable_usage()
    ),
    clique:register_usage(
        ["vmq-admin", "redis", "poll-main-queue", "disable"],
        redis_main_queue_poll_disable_usage()
    ),
    clique:register_usage(
        ["vmq-admin", "redis", "poll-main-queue", "show"],
        redis_main_queue_poll_show_usage()
    ),
    clique:register_usage(["vmq-admin", "redis", "message-store"], message_store_usage()),
    clique:register_usage(
        ["vmq-admin", "redis", "message-store", "enable"],
        message_store_enable_usage()
    ),
    clique:register_usage(
        ["vmq-admin", "redis", "message-store", "disable"],
        message_store_disable_usage()
    ),
    clique:register_usage(
        ["vmq-admin", "redis", "message-store", "show"],
        message_store_show_usage()
    ),
    clique:register_usage(["vmq-admin", "redis", "remap-subscriber"], remap_subscriber_usage()),
    clique:register_usage(
        ["vmq-admin", "redis", "remap-subscriber", "enable"],
        remap_subscriber_enable_usage()
    ),
    clique:register_usage(
        ["vmq-admin", "redis", "remap-subscriber", "disable"],
        remap_subscriber_disable_usage()
    ),
    clique:register_usage(
        ["vmq-admin", "redis", "remap-subscriber", "show"],
        remap_subscriber_show_usage()
    ),

    redis_show_cmd(),
    redis_main_queue_poll_enable_cmd(),
    redis_main_queue_poll_disable_cmd(),
    redis_main_queue_poll_show_cmd(),
    message_store_enable_cmd(),
    message_store_disable_cmd(),
    message_store_show_cmd(),
    remap_subscriber_enable_cmd(),
    remap_subscriber_disable_cmd(),
    remap_subscriber_show_cmd().

redis_main_queue_poll_enable_cmd() ->
    Cmd = ["vmq-admin", "redis", "poll-main-queue", "enable"],
    Callback = fun(_, _, _) ->
        ok = application:set_env(vmq_server, redis_main_queue_poll_enabled, true),
        vmq_config:configure_node(),
        ResumedWorkers = vmq_redis_queue_sup:resume_main_queue_polling(),
        [
            clique_status:text(
                io_lib:format(
                    "redis main-queue polling enabled; resumed_workers=~p",
                    [ResumedWorkers]
                )
            )
        ]
    end,
    clique:register_command(Cmd, [], [], Callback).

redis_main_queue_poll_disable_cmd() ->
    Cmd = ["vmq-admin", "redis", "poll-main-queue", "disable"],
    Callback = fun(_, _, _) ->
        ok = application:set_env(vmq_server, redis_main_queue_poll_enabled, false),
        vmq_config:configure_node(),
        [clique_status:text("Done.")]
    end,
    clique:register_command(Cmd, [], [], Callback).

redis_main_queue_poll_show_cmd() ->
    Cmd = ["vmq-admin", "redis", "poll-main-queue", "show"],
    Callback = fun(_, _, _) ->
        Enabled = application:get_env(vmq_server, redis_main_queue_poll_enabled, true),
        Workers =
            try
                lists:foldl(
                    fun
                        ({_, Pid, worker, [vmq_redis_queue]}, Acc) when is_pid(Pid) ->
                            Acc + 1;
                        (_, Acc) ->
                            Acc
                    end,
                    0,
                    supervisor:which_children(vmq_redis_queue_sup)
                )
            catch
                _:_ -> 0
            end,
        [
            clique_status:table([
                [
                    {'poll_enabled', Enabled},
                    {'workers', Workers}
                ]
            ])
        ]
    end,
    clique:register_command(Cmd, [], [], Callback).

redis_usage() ->
    [
        "vmq-admin redis <sub-command>\n\n",
        "  Manage Redis-backed runtime controls.\n\n",
        "  Sub-commands:\n",
        "    show                Show all Redis configuration flags\n",
        "    poll-main-queue     Manage polling for redis main queue workers\n",
        "    message-store       Manage message store operations\n",
        "    remap-subscriber    Manage remap/delete subscriber Redis calls\n",
        "  Use --help after a sub-command for more details.\n"
    ].

redis_main_queue_poll_usage() ->
    [
        "vmq-admin redis poll-main-queue <sub-command>\n\n",
        "  Manage redis main queue polling workers.\n\n",
        "  Sub-commands:\n",
        "    enable      Enable polling and resume worker poll timers\n",
        "    disable     Disable polling for redis main queue workers\n",
        "    show        Show current polling status\n",
        "  Use --help after a sub-command for more details.\n"
    ].

redis_main_queue_poll_enable_usage() ->
    [
        "vmq-admin redis poll-main-queue enable\n\n",
        "  Enables redis main queue polling at runtime and resumes polling timers\n",
        "  for all redis main queue workers on this node.\n\n"
    ].

redis_main_queue_poll_disable_usage() ->
    [
        "vmq-admin redis poll-main-queue disable\n\n",
        "  Disables redis main queue polling at runtime.\n",
        "  Existing poll timers are not rescheduled once they fire.\n\n"
    ].

redis_main_queue_poll_show_usage() ->
    [
        "vmq-admin redis poll-main-queue show\n\n",
        "  Shows current redis main queue polling state and worker count\n",
        "  on this node.\n\n"
    ].

message_store_enable_cmd() ->
    Cmd = ["vmq-admin", "redis", "message-store", "enable"],
    Callback = fun(_, _, _) ->
        ok = application:set_env(vmq_server, message_store_enabled, true),
        vmq_config:configure_node(),
        [clique_status:text("message-store enabled.")]
    end,
    clique:register_command(Cmd, [], [], Callback).

message_store_disable_cmd() ->
    Cmd = ["vmq-admin", "redis", "message-store", "disable"],
    Callback = fun(_, _, _) ->
        ok = application:set_env(vmq_server, message_store_enabled, false),
        vmq_config:configure_node(),
        [clique_status:text("message-store disabled.")]
    end,
    clique:register_command(Cmd, [], [], Callback).

message_store_show_cmd() ->
    Cmd = ["vmq-admin", "redis", "message-store", "show"],
    Callback = fun(_, _, _) ->
        Enabled = application:get_env(vmq_server, message_store_enabled, true),
        [clique_status:table([[{'message_store_enabled', Enabled}]])]
    end,
    clique:register_command(Cmd, [], [], Callback).

message_store_usage() ->
    [
        "vmq-admin redis message-store <sub-command>\n\n",
        "  Enable or disable the offline message store.\n\n",
        "  Sub-commands:\n",
        "    enable   Enable offline message store\n",
        "    disable  Disable offline message store\n",
        "    show     Show current message store state\n",
        "  Use --help after a sub-command for more details.\n"
    ].

message_store_enable_usage() ->
    [
        "vmq-admin redis message-store enable\n\n",
        "  Enables the offline message store.\n\n"
    ].

message_store_disable_usage() ->
    [
        "vmq-admin redis message-store disable\n\n",
        "  Disables the offline message store.\n\n"
    ].

message_store_show_usage() ->
    [
        "vmq-admin redis message-store show\n\n",
        "  Shows whether the offline message store is currently enabled.\n\n"
    ].

remap_subscriber_enable_cmd() ->
    Cmd = ["vmq-admin", "redis", "remap-subscriber", "enable"],
    Callback = fun(_, _, _) ->
        ok = application:set_env(vmq_server, remap_subscriber_enabled, true),
        vmq_config:configure_node(),
        [clique_status:text("remap-subscriber enabled.")]
    end,
    clique:register_command(Cmd, [], [], Callback).

remap_subscriber_disable_cmd() ->
    Cmd = ["vmq-admin", "redis", "remap-subscriber", "disable"],
    Callback = fun(_, _, _) ->
        ok = application:set_env(vmq_server, remap_subscriber_enabled, false),
        vmq_config:configure_node(),
        [clique_status:text("remap-subscriber disabled.")]
    end,
    clique:register_command(Cmd, [], [], Callback).

remap_subscriber_show_cmd() ->
    Cmd = ["vmq-admin", "redis", "remap-subscriber", "show"],
    Callback = fun(_, _, _) ->
        Enabled = application:get_env(vmq_server, remap_subscriber_enabled, true),
        [clique_status:table([[{'remap_subscriber_enabled', Enabled}]])]
    end,
    clique:register_command(Cmd, [], [], Callback).

remap_subscriber_usage() ->
    [
        "vmq-admin redis remap-subscriber <sub-command>\n\n",
        "  Enable or disable REMAP_SUBSCRIBER and DELETE_SUBSCRIBER Redis calls.\n\n",
        "  Sub-commands:\n",
        "    enable   Enable remap/delete subscriber Redis calls\n",
        "    disable  Disable remap/delete subscriber Redis calls\n",
        "    show     Show current remap subscriber state\n",
        "  Use --help after a sub-command for more details.\n"
    ].

remap_subscriber_enable_usage() ->
    [
        "vmq-admin redis remap-subscriber enable\n\n",
        "  Enables the REMAP_SUBSCRIBER and DELETE_SUBSCRIBER Redis calls.\n\n"
    ].

remap_subscriber_disable_usage() ->
    [
        "vmq-admin redis remap-subscriber disable\n\n",
        "  Disables the REMAP_SUBSCRIBER and DELETE_SUBSCRIBER Redis calls.\n",
        "  When disabled, session takeover across nodes is skipped.\n\n"
    ].

remap_subscriber_show_usage() ->
    [
        "vmq-admin redis remap-subscriber show\n\n",
        "  Shows whether the remap subscriber Redis calls are currently enabled.\n\n"
    ].

redis_show_cmd() ->
    Cmd = ["vmq-admin", "redis", "show"],
    Callback = fun(_, _, _) ->
        RedisEnabled = application:get_env(vmq_server, redis_enabled, true),
        RemapEnabled = application:get_env(vmq_server, remap_subscriber_enabled, true),
        MsgStoreEnabled = application:get_env(vmq_server, message_store_enabled, true),
        PollEnabled = application:get_env(vmq_server, redis_main_queue_poll_enabled, true),
        [
            clique_status:table([
                [
                    {'redis_enabled', RedisEnabled},
                    {'remap_subscriber_enabled', RemapEnabled},
                    {'message_store_enabled', MsgStoreEnabled},
                    {'redis_main_queue_poll_enabled', PollEnabled}
                ]
            ])
        ]
    end,
    clique:register_command(Cmd, [], [], Callback).

redis_show_usage() ->
    [
        "vmq-admin redis show\n\n",
        "  Shows the current state of all Redis configuration flags.\n\n"
    ].
