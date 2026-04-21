-module(vmq_enhanced_auth_rate_limiter).

-behaviour(gen_server).

-include("vmq_enhanced_auth.hrl").

-export([
    start_link/0,
    check_publish_rate/1,
    set_rate/2,
    delete_rate/1,
    list_rates/0
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-define(SERVER, ?MODULE).

-record(state, {}).

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-spec set_rate(Username :: binary(), MaxRate :: pos_integer()) -> ok.
set_rate(Username, MaxRate) when is_binary(Username), is_integer(MaxRate), MaxRate > 0 ->
    gen_server:call(?SERVER, {set_rate, Username, MaxRate}).

-spec delete_rate(Username :: binary()) -> ok | {error, not_found}.
delete_rate(Username) when is_binary(Username) ->
    gen_server:call(?SERVER, {delete_rate, Username}).

-spec list_rates() -> [{binary(), pos_integer()}].
list_rates() ->
    gen_server:call(?SERVER, list_rates).

-spec check_publish_rate(Username :: undefined | binary()) -> allow | drop.
check_publish_rate(undefined) ->
    allow;
check_publish_rate(Username) when is_binary(Username) ->
    case ets:lookup(?RATE_CONFIG_TBL, Username) of
        [] ->
            allow;
        [{Username, MaxRate}] ->
            Count = ets:update_counter(?RATE_COUNTER_TBL, Username, 1, {Username, 0}),
            case Count > MaxRate of
                true ->
                    vmq_enhanced_auth_metrics:incr_drop_metric(Username),
                    drop;
                false ->
                    allow
            end
    end.

init([]) ->
    ets:new(?RATE_CONFIG_TBL, [public, named_table, {read_concurrency, true}]),
    ets:new(?RATE_COUNTER_TBL, [public, named_table, {write_concurrency, true}]),
    ets:new(?RATE_LIMIT_METRICS_TBL, [public, named_table, {write_concurrency, true}]),
    {ok, TRef} = timer:send_interval(1000, reset_counters),
    put(reset_timer, TRef),
    load_config(),
    {ok, #state{}}.

handle_call({set_rate, Username, MaxRate}, _From, State) ->
    ets:insert(?RATE_CONFIG_TBL, {Username, MaxRate}),
    {reply, ok, State};
handle_call({delete_rate, Username}, _From, State) ->
    case ets:lookup(?RATE_CONFIG_TBL, Username) of
        [] ->
            {reply, {error, not_found}, State};
        _ ->
            ets:delete(?RATE_CONFIG_TBL, Username),
            {reply, ok, State}
    end;
handle_call(list_rates, _From, State) ->
    Rates = ets:tab2list(?RATE_CONFIG_TBL),
    {reply, Rates, State};
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(reset_counters, State) ->
    ets:delete_all_objects(?RATE_COUNTER_TBL),
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    case get(reset_timer) of
        undefined -> ok;
        TRef -> timer:cancel(TRef)
    end,
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

load_config() ->
    RateLimits = application:get_env(vmq_enhanced_auth, publish_rate_limit, []),
    lists:foreach(
        fun
            ({UsernameStr, MaxRate}) when is_integer(MaxRate), MaxRate > 0 ->
                Username = list_to_binary(UsernameStr),
                ets:insert(?RATE_CONFIG_TBL, {Username, MaxRate});
            (_) ->
                ok
        end,
        RateLimits
    ).
