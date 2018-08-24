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

-module(emqx_edge).

-include("emqx.hrl").

-import(proplists, [get_value/2, get_value/3]).

-export([start/1, stop/1]).

%% static edge cluster
start(static) ->
    emqx_edge_bridge:start().

stop(static) ->
    emqx_edge_bridge:stop().

%% get_edge_hosts() ->
%%     EdgeConf = emqx_config:get_env(edge, []),
%%     get_value(hosts, Edge).

%% get_host_num() ->
%%    {, Interfaces} = inet:getiflist(_).



%% start() ->
%%     EdgeNum = 2,
%%     Hosts = get_value(hosts, EdgeConf),
%%     EdgeLocalHost = lists:nth(EdgeNum, Hosts).

%% update_bridge_local(EdgeNum) ->
%%     EdgeLocalHost = lists:nth()
