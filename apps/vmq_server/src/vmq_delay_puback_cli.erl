-module(vmq_delay_puback_cli).
-export([register_cli/0]).
-behaviour(clique_handler).

register_cli() ->
    clique:register_usage(["vmq-admin", "delay_puback"], delay_puback_usage()),
    clique:register_usage(["vmq-admin", "delay_puback", "show"], show_usage()),
    clique:register_usage(["vmq-admin", "delay_puback", "enable"], enable_usage()),
    clique:register_usage(["vmq-admin", "delay_puback", "disable"], disable_usage()),

    show_cmd(),
    enable_cmd(),
    disable_cmd().

show_cmd() ->
    Cmd = ["vmq-admin", "delay_puback", "show"],
    Callback = fun(_, _, _) ->
        Config = vmq_config:get_env(delay_puback_config, []),
        Table = [[{acl_name, Name}, {enabled, Enabled}] || {Name, Enabled} <- Config],
        [clique_status:table(Table)]
    end,
    clique:register_command(Cmd, [], [], Callback).

enable_cmd() ->
    Cmd = ["vmq-admin", "delay_puback", "enable"],
    KeySpecs = [acl_name_keyspec()],
    Callback = fun(_, [{acl_name, Name}], _) ->
        ets:insert(vmq_delay_puback_cache, {Name, true}),
        Config = vmq_config:get_env(delay_puback_config, []),
        NewConfig = lists:keystore(Name, 1, Config, {Name, true}),
        vmq_config:set_global_env(vmq_server, delay_puback_config, NewConfig, true),
        [clique_status:text("Done")]
    end,
    clique:register_command(Cmd, KeySpecs, [], Callback).

disable_cmd() ->
    Cmd = ["vmq-admin", "delay_puback", "disable"],
    KeySpecs = [acl_name_keyspec()],
    Callback = fun(_, [{acl_name, Name}], _) ->
        ets:delete(vmq_delay_puback_cache, Name),
        Config = vmq_config:get_env(delay_puback_config, []),
        NewConfig = lists:keydelete(Name, 1, Config),
        vmq_config:set_global_env(vmq_server, delay_puback_config, NewConfig, true),
        [clique_status:text("Done")]
    end,
    clique:register_command(Cmd, KeySpecs, [], Callback).

acl_name_keyspec() ->
    {acl_name, [{typecast, fun(Name) -> list_to_binary(Name) end}]}.

delay_puback_usage() ->
    [
        "vmq-admin delay_puback <sub-command>\n\n",
        "  Manage Delayed PUBACK configuration.\n\n",
        "  Sub-commands:\n",
        "    show        Show current configuration\n",
        "    enable      Enable delayed PUBACK for an ACL\n",
        "    disable     Disable delayed PUBACK for an ACL\n"
    ].

show_usage() ->
    ["vmq-admin delay_puback show\n\n", "  Show current configuration.\n"].

enable_usage() ->
    ["vmq-admin delay_puback enable acl_name=<Name>\n\n", "  Enable delayed PUBACK for an ACL.\n"].

disable_usage() ->
    [
        "vmq-admin delay_puback disable acl_name=<Name>\n\n",
        "  Disable delayed PUBACK for an ACL.\n"
    ].
