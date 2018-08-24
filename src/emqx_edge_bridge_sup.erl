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

-module(emqx_edge_bridge_sup).

-behavior(supervisor).

-include("emqx.hrl").

-export([start_link/0, bridges/0]).

%% Supervisor callbacks
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% @doc List all bridges
-spec(bridges() -> [{node(), topic(), pid()}]).
bridges() ->
    [{Name, emqx_edge_bridge:status(Pid)} || {Name, Pid, _, _} <- supervisor:which_children(?MODULE)].

init([]) ->
    Edge = emqx_config:get_env(edge, []),
    BridgesOpts = proplists:get_value(bridge, Edge),
    Host = proplists:get_value(host, Edge),
    HostsList = proplists:get_value(hostslist, Edge),
    CloudAddr = proplists:get_value(cloud, Edge),
    NewBridgesOpts = update_bridge_opts(BridgesOpts, Host, HostsList, CloudAddr),
    [io:format("Opts: ~p.~n", [Opts]) || Opts <- BridgesOpts],
    [io:format("NewOpts: ~p.~n", [Opts]) || Opts <- NewBridgesOpts],
    Bridges = [spec(Opts)|| Opts <- NewBridgesOpts],
    {ok, {{one_for_one, 10, 100}, Bridges}}.

spec({Id, Options})->
    #{id       => Id,
      start    => {emqx_edge_bridge, start_link, [Id, Options]},
      restart  => permanent,
      shutdown => 5000,
      type     => worker,
      modules  => [emqx_edge_bridge]}.

update_bridge_opts(BridgesOpts, Host, HostsList, CloudAddr) ->
    Cloud = proplists:get_value(cloud, BridgesOpts),
    Beside = proplists:get_value(beside, BridgesOpts),
    Position = get_position(Host, HostsList),
    Length = length(HostsList),
    case Position of
        Pos when is_number(Pos) ->
            Pos;
        Host ->
            emqx_logger:error("[Edge] Unexpected host ~p.~n", [Host])
    end,
    BesideAddr = lists:nth(beside_address_pos(Position, Length), HostsList),
    io:format("BesideAddr: ~p~n", [BesideAddr]),
    insert_address(Cloud, Beside, BesideAddr, CloudAddr).

insert_address(Cloud, Beside, BesideAddr, CloudAddr) ->
    NewCloud = [{address, CloudAddr} | Cloud],
    NewBeside = [{address, BesideAddr} | Beside],
    [{cloud,NewCloud}, {beside, NewBeside}].
    
beside_address_pos(Position, Length) when Position < Length->
    Position + 1;
beside_address_pos(_Position, _Length) ->
    1.
    
get_position(SpecifiedHost, HostsList) ->
    get_position(SpecifiedHost, HostsList, 0).

get_position(SpecifiedHost, [Host|HostsList], Pos) ->
    case SpecifiedHost =:= Host of
        true ->
            Pos;
        false ->
            get_position(SpecifiedHost, HostsList, Pos + 1)
    end;
get_position(SpecifiedHost, [], _Pos) ->
    SpecifiedHost.
