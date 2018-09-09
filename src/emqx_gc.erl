%% Copyright (c) 2018 EMQ Technologies Co., Ltd. All Rights Reserved.
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

%% @doc This module manages an opaque collection of statistics data used to
%% force garbage collection on `self()' process when hitting thresholds.
%% Namely:
%% (1) Total number of messages passed through
%% (2) Total data volume passed through
%% (3) Time elasped since the first message passed through,
%%     because it makes no sense to force gc in an idle process.
%%
%% NOTE! About hibernation:
%%   If GC timer is enabled, there are chances for it to expire when a process
%%   is hibernating, this is very unnecessary from GC point of view because
%%   hibernation itself implies two GCs.
%%   However we will have to live with it since there is no `gen_server'
%%   callback to call before a process is going to hibernate.
%%   Hence it is important to set a gc-timer less than `hibernate_after',
%%   for a fatter chance that the gc-timer is cancelled before going
%%   into hibernation.
%% @end

-module(emqx_gc).

-author("Feng Lee <feng@emqtt.io>").

-export([init/0, inc_cnt_oct/3, timeout/2, reset/1]).
-export_type([st/0]).

-opaque st() :: #{ cnt => {integer(), integer()}
                 , oct => {integer(), integer()}
                 , sec => integer()
                 , ref => reference()
                 , tref => expired | reference()
                 }.
-define(disabled, disabled).
-define(timeout(Ref), {?MODULE, timeout, Ref}).

-spec init() -> st().
init() ->
    Cnt = get_cnt_threshold(),
    Oct = get_oct_threshold(),
    Sec = get_sec_threshold(),
    Part1 = [{cnt, {Cnt, Cnt}} || is_integer(Cnt)],
    Part2 = [{oct, {Oct, Oct}} || is_integer(Oct)],
    Part3 = [{sec, Sec} || is_integer(Sec)],
    maybe_start_timer(maps:from_list(lists:append([Part1, Part2, Part3]))).

%% @doc Increase count and bytes stats in one call,
%% ensure gc is triggered at most once, even if both thresholds are hit.
-spec inc_cnt_oct(st(), pos_integer(), pos_integer()) -> st().
inc_cnt_oct(St0, Cnt, Oct) ->
    case inc(St0, cnt, Cnt) of
        {true, St} ->
            St;
        {false, St1} ->
            {_, St} = inc(St1, oct, Oct),
            St
    end.

%% @doc This function sholld be called when the ?timeout(reference()) message
%% is received by self()
-spec timeout(st(), reference()) -> st().
timeout(#{ref := Ref} = St, Ref) -> do_gc(St#{tref := expired});
timeout(St, _) -> St. %% timeout race with cancel-timer

%% @doc Reset counters to zero, and cancel gc-timer if started.
reset(St) -> reset(cnt, reset(oct, reset_timer(St))).

%% ======== Internals ========

%% maybe start gc timer.
maybe_start_timer(#{tref := Ref} = St) when is_reference(Ref) ->
    %% timer already started
    St;
maybe_start_timer(#{sec := Sec} = St) ->
    Ref = make_ref(),
    Tref = erlang:send_after(timer:seconds(Sec), self(), ?timeout(Ref)),
    St#{ref => Ref,
        tref => Tref
       };
maybe_start_timer(St) ->
    %% Timer based GC is not enabled
    St.

-spec inc(st(), cnt | oct, pos_integer()) -> {boolean(), st()}.
inc(St, Key, Num) ->
    case maps:get(Key, St, ?disabled) of
        ?disabled ->
            {false, maybe_start_timer(St)};
        {Init, Remain} when Remain > Num ->
            {false, maybe_start_timer(maps:put(Key, {Init, Remain - Num}, St))};
        _ ->
            {true, do_gc(St)}
    end.

do_gc(St) ->
    erlang:garbage_collect(),
    reset(St).

reset_timer(#{tref := Ref} = St) ->
    _ = is_reference(Ref) andalso erlang:cancel_timer(Ref),
    maps:without([ref, tref], St);
reset_timer(St) -> St.

reset(Key, St) ->
    case maps:get(Key, St, ?disabled) of
        ?disabled -> St;
        {Init, _} -> maps:put(Key, {Init, Init}, St)
    end.

get_cnt_threshold() -> get_num_conf(conn_force_gc_count).

get_oct_threshold() -> get_num_conf(conn_force_gc_bytes).

get_sec_threshold() -> get_num_conf(conn_force_gc_interval).

get_num_conf(Key) ->
    case application:get_env(?APPLICATION, Key) of
        {ok, I} when I > 0 -> I + rand:uniform(I) - 1;
        {ok, I} when I =< 0 -> ?disabled;
        undefined -> ?disabled
    end.

