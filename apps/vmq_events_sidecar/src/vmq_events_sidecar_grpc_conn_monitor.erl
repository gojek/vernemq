%% Copyright Gojek

%%%-------------------------------------------------------------------
%% @doc Tracks and optionally recycles the gRPC channel pool's connections.
%%
%% == Why this exists ==
%%
%% grpc-erl opens its connections once and never replaces a healthy one: it has
%% no connection ageing, no re-resolution and no load-balancing policy. Our
%% connections terminate at the proxy rather than at the webhook, so the
%% webhook's MaxConnectionAge never reaches us either. Left alone they pin to
%% whichever proxy endpoints they resolved at boot, for the lifetime of the node.
%%
%% Recycling closes a connection so that grpc_client re-dials, which re-resolves
%% DNS.
%%
%%   xgrpc/pool                        here
%%   --------------------------------  ------------------------------------
%%   conn.createdAt                    FirstSeen in ?TABLE
%%   conn.dl (jittered deadline)       DeadlineSeconds in ?TABLE
%%   maxLifeTimeout 10m                grpc_connection_max_age_seconds
%%   stdDev 10s (normal)               grpc_connection_age_jitter_seconds
%%   age checked per RPC in get()      deadline checked per tick
%%   refreshConnection -> cc.Close()   gun:close/1
%%
%% == Cost, when enabled ==
%%
%% Closing a connection fails whatever was in flight on it. grpc_client replies
%% {error, {connection_down, Reason}} to those callers immediately, so they are
%% counted as grpc_call_result{result="connection_down"} rather than waiting out a
%% timeout. As a fraction of throughput the loss is latency / max_age
%%
%% == Notes ==
%%
%% gun creates one process per connection under `gun_conns_sup', and grpc-erl is
%% gun's only user in this release, so that supervisor's children are exactly our
%% channel-pool connections.
%%
%% Age is tracked here because Erlang exposes no process start time, so it is
%% measured from first sight rather than from the TCP handshake. Sampling also
%% means a connection that comes and goes entirely between ticks is missed, which
%% makes grpc_connects a lower bound on churn.
%%
%% == What lives where ==
%%
%% Per-connection bookkeeping is private gen_server state. Only the aggregate is
%% published, to a single ETS row, because the reader is the metrics scrape running
%% in another process: a gen_server:call from there would queue behind a tick, and
%% a tick can block in gun:close/1 (supervisor:terminate_child). Reading live
%% connections at scrape time had the same problem one process further along --
%% supervisor:which_children/1 contends with the very terminate_child we issue.
%%
%% The published aggregate is therefore up to one interval stale, which is
%% immaterial for a connection count and age. grpc_connection_sample_age_seconds
%% exposes that staleness so a wedged sampler is visible rather than silently
%% serving a frozen gauge.
%% @end
%%%-------------------------------------------------------------------

-module(vmq_events_sidecar_grpc_conn_monitor).
-include("../include/vmq_events_sidecar.hrl").

-behaviour(gen_server).

%% API
-export([
    start_link/0,
    stats/0,
    sample_now/0,
    recycle_oldest_now/0
]).

%% gen_server callbacks
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

%% Pid => {FirstSeen, DeadlineSeconds}. DeadlineSeconds 0 means never recycle.
-type conns() :: #{pid() => {integer(), non_neg_integer()}}.

-record(state, {
    conns = #{} :: conns(),
    max_age_seconds = 0 :: non_neg_integer()
}).

-define(TABLE, vmq_events_sidecar_grpc_conns).
-define(INTERVAL_MS, 5000).
-define(DEFAULT_MAX_AGE_SECONDS, 0).
-define(DEFAULT_JITTER_SECONDS, 10).
-define(DEFAULT_POOL_SIZE, 100).
-define(RECONNECT_TIMEOUT_MS, 5000).

%%====================================================================
%% API
%%====================================================================

-spec start_link() -> {ok, pid()} | ignore | {error, any()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc `{Connections, AgeOfOldestSeconds, SampleAgeSeconds}' as of the last tick,
%% or `undefined' when this process is not running, i.e. gRPC is disabled.
-spec stats() ->
    undefined | {non_neg_integer(), non_neg_integer(), non_neg_integer()}.
stats() ->
    case ets:whereis(?TABLE) of
        undefined ->
            undefined;
        _Tid ->
            case ets:lookup(?TABLE, stats) of
                [{stats, Connections, MaxAge, UpdatedAt}] ->
                    SampleAge = max(0, erlang:monotonic_time(second) - UpdatedAt),
                    {Connections, MaxAge, SampleAge};
                [] ->
                    {0, 0, 0}
            end
    end.

%% @doc Sample now rather than waiting for the next tick.
-spec sample_now() -> ok.
sample_now() ->
    gen_server:call(?MODULE, sample, ?RECONNECT_TIMEOUT_MS).

%% @doc Recycle the oldest connection now, ignoring both its deadline and the
%% whole-pool guard. For tests, and for rotating a connection by hand.
-spec recycle_oldest_now() -> {ok, pid()} | none.
recycle_oldest_now() ->
    gen_server:call(?MODULE, recycle_oldest, 2 * ?RECONNECT_TIMEOUT_MS).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([]) ->
    ?TABLE = ets:new(?TABLE, [named_table, protected, set, {read_concurrency, true}]),
    %% Sample immediately so the metrics are populated before the first scrape.
    {ok, sample_and_recycle(#state{max_age_seconds = max_age_seconds()}), ?INTERVAL_MS}.

handle_call(sample, _From, State) ->
    {reply, ok, sample_and_recycle(State), ?INTERVAL_MS};
handle_call(recycle_oldest, _From, State0) ->
    case oldest_connection(State0) of
        undefined ->
            {reply, none, State0, ?INTERVAL_MS};
        Pid ->
            {reply, {ok, Pid}, close_and_reconnect(Pid, State0), ?INTERVAL_MS}
    end;
handle_call(_Request, _From, State) ->
    {reply, ok, State, ?INTERVAL_MS}.

handle_cast(_Msg, State) ->
    {noreply, State, ?INTERVAL_MS}.

handle_info(timeout, State) ->
    {noreply, sample_and_recycle(State), ?INTERVAL_MS};
handle_info(_Info, State) ->
    {noreply, State, ?INTERVAL_MS}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%====================================================================
%% Sampling
%%====================================================================

sample_and_recycle(State0) ->
    State1 = reassign_deadlines_if_max_age_changed(State0),
    case live_connection_pids() of
        undefined ->
            %% gun is not running, so there is nothing to track. Leave the state
            %% alone rather than discarding age history.
            State1;
        LivePids ->
            NowSeconds = erlang:monotonic_time(second),
            State2 = forget_closed_connections(LivePids, State1),
            State3 = track_new_connections(LivePids, NowSeconds, State2),
            %% Published before recycling, so the count reflects the pool as it
            %% stood at sample time rather than mid-teardown.
            publish_stats(NowSeconds, length(LivePids), State3),
            recycle_due_connections(NowSeconds, LivePids, State3)
    end.

%% Deadlines are absolute, assigned when a connection is first seen, so a change
%% to max_age would otherwise only reach connections established afterwards --
%% meaning enabling recycling on a running node did nothing at all until the pool
%% happened to churn. Reassign on change instead, spreading the new deadlines
%% because a pool of uniform age would otherwise come due all at once.
reassign_deadlines_if_max_age_changed(State = #state{max_age_seconds = Previous, conns = Conns}) ->
    case max_age_seconds() of
        Previous ->
            State;
        Current ->
            lager:info(
                "gRPC connection max age changed ~p -> ~p, reassigning ~p deadline_seconds(s)",
                [Previous, Current, maps:size(Conns)]
            ),
            Reassigned = maps:map(
                fun(_Pid, {FirstSeen, _DeadlineSeconds}) ->
                    {FirstSeen, deadline_seconds(spread_across_period, Current)}
                end,
                Conns
            ),
            State#state{max_age_seconds = Current, conns = Reassigned}
    end.

forget_closed_connections(LivePids, State = #state{conns = Conns}) ->
    Live = sets:from_list(LivePids),
    State#state{conns = maps:filter(fun(Pid, _V) -> sets:is_element(Pid, Live) end, Conns)}.

track_new_connections(LivePids, NowSeconds, State) ->
    #state{conns = Tracked, max_age_seconds = MaxAgeSeconds} = State,
    case [Pid || Pid <- LivePids, not maps:is_key(Pid, Tracked)] of
        [] ->
            State;
        NewPids ->
            Mode = deadline_mode_for_batch(NewPids),
            Added = maps:from_list([
                {Pid, {NowSeconds, deadline_seconds(Mode, MaxAgeSeconds)}}
             || Pid <- NewPids
            ]),
            vmq_events_sidecar_metrics:incr_grpc_connects(length(NewPids)),
            State#state{conns = maps:merge(Tracked, Added)}
    end.

%% A single new connection is a replacement and gets a full lifetime. Several
%% appearing at once are a cohort -- at boot, or after the proxy dropped
%% everything -- and their deadlines must be spread, or they expire together on
%% every subsequent cycle for the life of the node.
deadline_mode_for_batch([_Single]) -> full_lifetime;
deadline_mode_for_batch(_Cohort) -> spread_across_period.

%% 0 means never recycle.
deadline_seconds(_Mode, 0) ->
    0;
deadline_seconds(spread_across_period, MaxAge) ->
    rand:uniform(MaxAge);
deadline_seconds(full_lifetime, MaxAge) ->
    case min(jitter_seconds(), MaxAge - 1) of
        JitterSeconds when JitterSeconds =< 0 -> MaxAge;
        JitterSeconds -> MaxAge - JitterSeconds + rand:uniform(2 * JitterSeconds + 1) - 1
    end.

publish_stats(NowSeconds, Connections, #state{conns = Conns}) ->
    MaxAge =
        case maps:values(Conns) of
            [] -> 0;
            Values -> lists:max([NowSeconds - FirstSeen || {FirstSeen, _DeadlineSeconds} <- Values])
        end,
    true = ets:insert(?TABLE, {stats, Connections, MaxAge, NowSeconds}),
    ok.

%%====================================================================
%% Recycling
%%====================================================================

recycle_due_connections(NowSeconds, LivePids, State) ->
    case length(LivePids) >= configured_pool_size() of
        true ->
            recycle_oldest_due(NowSeconds, recycle_budget_per_tick(), State);
        false ->
            %% Pool is short: something we closed has not come back, or the
            %% endpoint is unreachable. Pause rather than close more.
            State
    end.

%% A pool of N connections with a lifetime of MaxAge needs N * Interval / MaxAge
%% recycles per tick to hold that age. Hardcoding this silently stops honouring
%% max_age as the pool grows -- at 350 connections and 600s it needs 3 per tick,
%% and at 1 per tick the pool would instead settle at an age of ~1750s.
recycle_budget_per_tick() ->
    case max_age_seconds() of
        0 ->
            0;
        MaxAge ->
            IntervalSeconds = ?INTERVAL_MS div 1000,
            max(1, ceil(configured_pool_size() * IntervalSeconds / MaxAge))
    end.

recycle_oldest_due(_Now, 0, State) ->
    State;
recycle_oldest_due(NowSeconds, Remaining, State) ->
    case oldest_due_connection(NowSeconds, State) of
        undefined ->
            State;
        Pid ->
            recycle_oldest_due(NowSeconds, Remaining - 1, close_and_reconnect(Pid, State))
    end.

%% gun:close/1 is supervisor:terminate_child on gun_conns_sup, so the connection
%% is gone once this returns and grpc_client sees the DOWN. It re-dials only on
%% its next request though, which is not good enough at a low rollout percentage,
%% so trigger the reconnect explicitly.
close_and_reconnect(Pid, State = #state{conns = Conns}) ->
    OwningClient = owning_grpc_client(Pid),
    _ =
        try
            gun:close(Pid)
        catch
            Class:Reason ->
                lager:debug("gun:close/1 on ~p failed: ~p:~p", [Pid, Class, Reason]),
                ok
        end,
    vmq_events_sidecar_metrics:incr_grpc_connections_recycled(),
    trigger_reconnect_async(OwningClient),
    State#state{conns = maps:remove(Pid, Conns)}.

%% The gun process's owner is the grpc_client worker that dialled it. Read it
%% while that process is still alive to answer.
owning_grpc_client(GunPid) ->
    try
        maps:get(owner, gun:info(GunPid))
    catch
        _:_ -> undefined
    end.

%% Off this process: health_check/2 is a call into a worker that may be mid
%% request, and the ticker must not block behind it. The explicit timeout matters
%% because grpc_client defaults connect_timeout to infinity.
trigger_reconnect_async(undefined) ->
    ok;
trigger_reconnect_async(Owner) ->
    _ = spawn(fun() ->
        try grpc_client:health_check(Owner, #{connect_timeout => ?RECONNECT_TIMEOUT_MS}) of
            ok ->
                ok;
            {error, Reason} ->
                lager:warning("gRPC reconnect after recycle failed: ~p", [Reason])
        catch
            Class:Error ->
                lager:warning("gRPC reconnect after recycle crashed: ~p:~p", [Class, Error])
        end
    end),
    ok.

%%====================================================================
%% Queries over tracked connections
%%====================================================================

oldest_connection(#state{conns = Conns}) ->
    pid_of_oldest([{FirstSeen, Pid} || {Pid, {FirstSeen, _DeadlineSeconds}} <- maps:to_list(Conns)]).

oldest_due_connection(NowSeconds, #state{conns = Conns}) ->
    pid_of_oldest([
        {FirstSeen, Pid}
     || {Pid, {FirstSeen, DeadlineSeconds}} <- maps:to_list(Conns),
        DeadlineSeconds > 0,
        NowSeconds - FirstSeen >= DeadlineSeconds
    ]).

pid_of_oldest([]) -> undefined;
pid_of_oldest(Candidates) -> element(2, lists:min(Candidates)).

%%====================================================================
%% Connections and config
%%====================================================================

live_connection_pids() ->
    case whereis(gun_conns_sup) of
        undefined ->
            undefined;
        _Sup ->
            [
                Pid
             || {_Id, Pid, _Type, _Mods} <- supervisor:which_children(gun_conns_sup), is_pid(Pid)
            ]
    end.

max_age_seconds() ->
    max(0, application:get_env(?APP, grpc_connection_max_age_seconds, ?DEFAULT_MAX_AGE_SECONDS)).

jitter_seconds() ->
    max(0, application:get_env(?APP, grpc_connection_age_jitter_seconds, ?DEFAULT_JITTER_SECONDS)).

configured_pool_size() ->
    max(1, application:get_env(?APP, grpc_pool_size, ?DEFAULT_POOL_SIZE)).
