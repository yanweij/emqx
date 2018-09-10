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

-module(emqx_gc_tests).

-include_lib("eunit/include/eunit.hrl").

trigger_by_timer_test() ->
    with_env([{conn_force_gc_interval, 1}],
             fun() ->
                     ok = emqx_gc:inc(0, 0),
                     receive
                         {emqx_gc, timeout, Ref} ->
                             ok = emqx_gc:timeout(Ref),
                             St0 = inspect(),
                             ?assertNot(maps:is_key(tref, St0)),
                             %% calling timeout/1 again with stale ref should
                             %% not changing anything.
                             ok = emqx_gc:timeout(Ref),
                             St1 = inspect(),
                             ?assertEqual(St0, St1),
                             ok
                     after
                         2000 ->
                             erlang:error(timeout)
                     end
             end).

trigger_by_timer_2_test() ->
    with_env([{conn_force_gc_interval, 1}],
             fun() ->
                     ok = emqx_gc:inc(0, 0), %% trigger gc-stats init
                     St0 = inspect(),
                     ?assert(maps:is_key(tref, St0)),
                     %% cancel the old timer
                     ok = emqx_gc:reset(),
                     St1 = inspect(),
                     ?assertNot(maps:is_key(tref, St1)),
                     %% tigger a new timer start
                     ok = emqx_gc:inc(1, 2),
                     St2 = inspect(),
                     ?assert(maps:is_key(tref, St2)),
                     ?assert(maps:get(tref, St0) =/= maps:get(tref, St2)),
                     ok
             end).

trigger_by_cnt_test() ->
    with_env([{conn_force_gc_count, 2},
              {conn_force_gc_bytes, 0}, %% disable
              {conn_force_gc_interval, 0} %% disable
             ],
             fun() ->
                     ok = emqx_gc:inc(1, 1000),
                     St1 = inspect(),
                     ?assertMatch({_, Remain} when Remain > 0, maps:get(cnt, St1)),
                     ok = emqx_gc:inc(2, 2),
                     St2 = inspect(),
                     ok = emqx_gc:inc(0, 2000),
                     St3 = inspect(),
                     ?assertEqual(St2, St3),
                     ?assertMatch({N, N}, maps:get(cnt, St2)),
                     ?assertNot(maps:is_key(oct, St2)),
                     ok
             end).


trigger_by_oct_test() ->
    with_env([{conn_force_gc_count, 2},
              {conn_force_gc_bytes, 2},
              {conn_force_gc_interval, 0} %% disable
             ],
             fun() ->
                     ok = emqx_gc:inc(1, 1),
                     St1 = inspect(),
                     ?assertMatch({_, Remain} when Remain > 0, maps:get(oct, St1)),
                     ok = emqx_gc:inc(2, 2),
                     St2 = inspect(),
                     ?assertMatch({N, N}, maps:get(oct, St2)),
                     ?assertMatch({M, M}, maps:get(cnt, St2)),
                     ok
             end).

get_env(Key) -> application:get_env(?APPLICATION, Key).
set_env(Key, Val) -> application:set_env(?APPLICATION, Key, Val).
unset_env(Key) -> application:unset_env(?APPLICATION, Key).

with_env([], F) ->
    erlang:erase(emqx_gc),
    F();
with_env([{Key, Val} | Rest], F) ->
    Origin = get_env(Key),
    try
        ok = set_env(Key, Val),
        with_env(Rest, F)
    after
        case Origin of
            undefined -> ok = unset_env(Key);
            _ -> ok = set_env(Key, Origin)
        end
    end.

inspect() -> erlang:get(emqx_gc).
