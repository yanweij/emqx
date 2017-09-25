%%--------------------------------------------------------------------
%% Copyright (c) 2013-2017 EMQ Enterprise, Inc. (http://emqtt.io)
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
%%--------------------------------------------------------------------

%% @doc HTTP publish API and Websocket client.

-module(emqttd_http).

-author("Feng Lee <feng@emqtt.io>").

-include("emqttd.hrl").

-include("emqttd_protocol.hrl").

-include("emqttd_internal.hrl").

-import(proplists, [get_value/2, get_value/3]).

-export([handler/0, dispatcher/0, api_list/0, handle_request/2]).

%%--------------------------------------------------------------------
%% Handler and Dispatcher
%%--------------------------------------------------------------------

handler() ->
    {?MODULE, handle_request, [dispatcher()]}.

dispatcher() ->
    dispatcher(api_list()).

api_list() ->
    [#{method => Method, path => Path, reg => Reg, function => Fun, args => Args}
      || {http_api, [{Method, Path, Reg, Fun, Args}]} <- emqttd_rest:module_info(attributes)].

%%--------------------------------------------------------------------
%% Handle HTTP Request
%%--------------------------------------------------------------------

handle_request(Req, Dispatch) ->
    Method = Req:get(method),
    case Req:get(path) of
        "/status" when Method =:= 'HEAD'; Method =:= 'GET' ->
            {InternalStatus, _ProvidedStatus} = init:get_status(),
            AppStatus = case lists:keysearch(emqttd, 1, application:which_applications()) of
                false         -> not_running;
                {value, _Val} -> running
            end,
            Status = io_lib:format("Node ~s is ~s~nemqttd is ~s",
                                    [node(), InternalStatus, AppStatus]),
            Req:ok({"text/plain", iolist_to_binary(Status)});
        "/" when Method =:= 'HEAD'; Method =:= 'GET' ->
            respond(Req, 200, [ [{method, M}, {path, iolist_to_binary(["api/v2/", P])}]
                                || #{method := M, path := P} <- api_list() ]);
        "/api/v2/" ++ Url ->
            if_authorized(Req, fun() -> Dispatch(Method, Url, Req) end);
        _ ->
            respond(Req, 404, [])
    end.

dispatcher(APIs) ->
    fun(Method, Url, Req) ->
        io:format("~s ~s: ~p~n", [Method, Url, Req]),
        case filter(Url, Method, APIs) of
            [#{reg := Regexp, function := Function, args := FilterArgs}] ->
                case params(Req) of
                    {error, Error1} ->
                        respond(Req, 200, Error1);
                    Params ->
                        case {check_params(Params, FilterArgs),
                              check_params_type(Params, FilterArgs)} of
                            {true, true} ->
                                {match, [MatchList]} = re:run(Url, Regexp, [global, {capture, all_but_first, list}]),
                                Args = lists:append([[Method, Params], MatchList]),
                                lager:debug("Mod:~p, Fun:~p, Args:~p", [emqttd_rest, Function, Args]),
                                case catch apply(emqttd_rest, Function, Args) of
                                    {ok, Data} ->
                                        respond(Req, 200, [{code, ?SUCCESS}, {result, Data}]);
                                    {error, Error} ->
                                        respond(Req, 200, Error);
                                    {'EXIT', Reason} ->
                                        lager:error("Execute API '~s' Error: ~p", [Url, Reason]),
                                        respond(Req, 404, [])
                                end;
                            {false, _} ->
                                respond(Req, 200, [{code, ?ERROR7}, {message, <<"params error">>}]);
                            {_, false} ->
                                respond(Req, 200, [{code, ?ERROR8}, {message, <<"params type error">>}])
                        end
                end;
            _ ->
                lager:error("No match Url:~p", [Url]),
                respond(Req, 404, [])
        end
    end.

%%--------------------------------------------------------------------
%% Basic Authorization
%%--------------------------------------------------------------------

if_authorized(Req, Fun) ->
    case authorized(Req) of
        true  -> Fun();
        false -> respond(Req, 401,  [])
    end.

authorized(Req) ->
    case Req:get_header_value("Authorization") of
        undefined ->
            false;
        "Basic " ++ BasicAuth ->
            {Username, Password} = user_passwd(BasicAuth),
            case emqttd_mgmt:check_user(Username, Password) of
                ok ->
                    true;
                {error, Reason} ->
                    lager:error("HTTP Auth failure: username=~s, reason=~p", [Username, Reason]),
                    false
            end
    end.

user_passwd(BasicAuth) ->
    list_to_tuple(binary:split(base64:decode(BasicAuth), <<":">>)).

respond(Req, 401, Data) ->
    Req:respond({401, [{"WWW-Authenticate", "Basic Realm=\"emqx control center\""}], Data});
respond(Req, 404, Data) ->
    Req:respond({404, [{"Content-Type", "text/plain"}], Data});
respond(Req, 200, Data) ->
    Req:respond({200, [{"Content-Type", "application/json"}], to_json(Data)});
respond(Req, Code, Data) ->
    Req:respond({Code, [{"Content-Type", "text/plain"}], Data}).

filter(Url, Method, APIs) ->
    lists:filter(fun(#{reg := Regexp, method := Method1}) ->
        case re:run(Url, Regexp, [global, {capture, all_but_first, list}]) of
            {match, _} -> Method =:= Method1;
            _ -> false
        end
    end, APIs).

params(Req) ->
    Method = Req:get(method),
    case Method of
        'GET' ->
            mochiweb_request:parse_qs(Req);
        _ ->
            case Req:recv_body() of
                <<>> -> [];
                undefined -> [];
                Body ->
                    case jsx:is_json(Body) of
                        true -> jsx:decode(Body);
                        false ->
                            lager:error("Body:~p", [Body]),
                            {error, [{code, ?ERROR9}, {message, <<"Body not json">>}]}
                    end
            end
    end.

check_params(_Params, Args) when Args =:= [] ->
    true;
check_params(Params, Args)->
    not lists:any(fun({Item, _Type}) -> undefined =:= proplists:get_value(Item, Params) end, Args).

check_params_type(_Params, Args) when Args =:= [] ->
    true;
check_params_type(Params, Args) ->
    not lists:any(fun({Item, Type}) ->
        Val = proplists:get_value(Item, Params),
        case Type of
            int -> not is_integer(Val);
            binary -> not is_binary(Val);
            bool -> not is_boolean(Val)
        end
    end, Args).

to_json([])   -> <<"[]">>;
to_json(Data) -> iolist_to_binary(mochijson2:encode(Data)).

