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

%% @doc MQTT Packet Parser
-module(emqttd_parser).

-author("Feng Lee <feng@emqtt.io>").

-include("emqttd.hrl").

-include("emqttd_protocol.hrl").

%% API
-export([initial_state/0, initial_state/1, parse/2]).

-type(max_packet_size() :: 1..?MAX_PACKET_SIZE).

-spec(initial_state() -> {none, max_packet_size()}).
initial_state() ->
    initial_state(?MAX_PACKET_SIZE).

%% @doc Initialize a parser
-spec(initial_state(max_packet_size()) -> {none, max_packet_size()}).
initial_state(MaxSize) ->
    {none, MaxSize}.

%% @doc Parse MQTT Packet
-spec(parse(binary(), {none, pos_integer()} | fun())
            -> {ok, mqtt_packet()} | {error, any()} | {more, fun()}).
parse(<<>>, {none, MaxLen}) ->
    {more, fun(Bin) -> parse(Bin, {none, MaxLen}) end};
parse(<<Type:4, Dup:1, QoS:2, Retain:1, Rest/binary>>, {none, Limit}) ->
    parse_remaining_len(Rest, #mqtt_packet_header{type   = Type,
                                                  dup    = bool(Dup),
                                                  qos    = fixqos(Type, QoS),
                                                  retain = bool(Retain)}, Limit);
parse(Bin, Cont) -> Cont(Bin).

parse_remaining_len(<<>>, Header, Limit) ->
    {more, fun(Bin) -> parse_remaining_len(Bin, Header, Limit) end};
parse_remaining_len(Rest, Header, Limit) ->
    parse_remaining_len(Rest, Header, 1, 0, Limit).

parse_remaining_len(_Bin, _Header, _Multiplier, Length, MaxLen)
    when Length > MaxLen ->
    {error, invalid_mqtt_frame_len};
parse_remaining_len(<<>>, Header, Multiplier, Length, Limit) ->
    {more, fun(Bin) -> parse_remaining_len(Bin, Header, Multiplier, Length, Limit) end};
%% optimize: match PUBACK, PUBREC, PUBREL, PUBCOMP, UNSUBACK...
parse_remaining_len(<<0:1, 2:7, Rest/binary>>, Header, 1, 0, _Limit) ->
    parse_frame(Rest, Header, 2);
%% optimize: match PINGREQ...
parse_remaining_len(<<0:8, Rest/binary>>, Header, 1, 0, _Limit) ->
    parse_frame(Rest, Header, 0);
parse_remaining_len(<<1:1, Len:7, Rest/binary>>, Header, Multiplier, Value, Limit) ->
    parse_remaining_len(Rest, Header, Multiplier * ?HIGHBIT, Value + Len * Multiplier, Limit);
parse_remaining_len(<<0:1, Len:7, Rest/binary>>, Header,  Multiplier, Value, MaxLen) ->
    FrameLen = Value + Len * Multiplier,
    if
        FrameLen > MaxLen -> {error, invalid_mqtt_frame_len};
        true -> parse_frame(Rest, Header, FrameLen)
    end.

parse_frame(Bin, #mqtt_packet_header{type = Type, qos  = Qos} = Header, Length) ->
    case {Type, Bin} of
        {?CONNECT, <<FrameBin:Length/binary, Rest/binary>>} ->
            {ProtoName, Rest1} = parse_utf(FrameBin),
            %% Fix mosquitto bridge: 0x83, 0x84
            <<_Bridge:4, ProtoVersion:4, Rest2/binary>> = Rest1,
            <<UsernameFlag : 1,
              PasswordFlag : 1,
              WillRetain   : 1,
              WillQos      : 2,
              WillFlag     : 1,
              CleanSess    : 1,
              _Reserved    : 1,
              KeepAlive    : 16/big,
              Rest3/binary>>   = Rest2,
            {Properties, Rest4} = case ProtoVersion of
                                      ?MQTT_PROTO_V5 -> parse_properties(Rest3);
                                      _MQTT_PROTO_V3 -> {[], Rest3}
                                  end,

            {ClientId,  Rest5} = parse_utf(Rest4),
            {WillTopic, Rest6} = parse_utf(Rest5, WillFlag),
            {WillMsg,   Rest7} = parse_msg(Rest6, WillFlag),
            {UserName,  Rest8} = parse_utf(Rest7, UsernameFlag),
            {PasssWord, <<>>}  = parse_utf(Rest8, PasswordFlag),
            case protocol_name_approved(ProtoVersion, ProtoName) of
                true ->
                    wrap(Header,
                         #mqtt_packet_connect{
                           proto_ver   = ProtoVersion,
                           proto_name  = ProtoName,
                           will_retain = bool(WillRetain),
                           will_qos    = WillQos,
                           will_flag   = bool(WillFlag),
                           clean_sess  = bool(CleanSess),
                           keep_alive  = KeepAlive,
                           client_id   = ClientId,
                           will_topic  = WillTopic,
                           will_msg    = WillMsg,
                           username    = UserName,
                           password    = PasssWord,
                           properties  = Properties}, Rest);
               false ->
                    {error, protocol_header_corrupt}
            end;
        %{?CONNACK, <<FrameBin:Length/binary, Rest/binary>>} ->
        %    <<_Reserved:7, SP:1, ReturnCode:8>> = FrameBin,
        %    wrap(Header, #mqtt_packet_connack{ack_flags = SP,
        %                                      return_code = ReturnCode }, Rest);
        {?PUBLISH, <<FrameBin:Length/binary, Rest/binary>>} ->
            {TopicName, Rest1} = parse_utf(FrameBin),
            {PacketId, Rest2}  = case Qos of
                                      0 -> {undefined, Rest1};
                                      _ -> <<Id:16/big, R/binary>> = Rest1,
                                          {Id, R}
                                  end,
            %%TODO: compatile with mqttv3...
            {Properties, Payload} = parse_properties(Rest2),
            wrap(Header, #mqtt_packet_publish{topic_name = TopicName,
                                              packet_id  = PacketId,
                                              properties = Properties},
                 Payload, Rest);
        {PubAck, <<FrameBin:Length/binary, Rest/binary>>} when PubAck =:= ?PUBACK;
                                                               PubAck =:= ?PUBREC;
                                                               PubAck =:= ?PUBREL;
                                                               PubAck =:= ?PUBCOMP ->
            %%TODO: compatile with mqttv3...
            <<PacketId:16/big, ReturnCode:8, Rest1/binary>> = FrameBin,
            %%TODO: compatile with mqttv3...
            {Properties, <<>>} = parse_properties(Rest1),
            wrap(Header, #mqtt_packet_puback{packet_id   = PacketId,
                                             return_code = ReturnCode,
                                             properties  = Properties}, Rest);
        {?SUBSCRIBE, <<FrameBin:Length/binary, Rest/binary>>} ->
            %% 1 = Qos,
            <<PacketId:16/big, Rest1/binary>> = FrameBin,
            {Properties, Rest2} = parse_properties(Rest1),
            TopicTable = parse_topics(?SUBSCRIBE, Rest2, []),
            wrap(Header, #mqtt_packet_subscribe{packet_id   = PacketId,
                                                properties  = Properties,
                                                topic_table = TopicTable}, Rest);
        %{?SUBACK, <<FrameBin:Length/binary, Rest/binary>>} ->
        %    <<PacketId:16/big, Rest1/binary>> = FrameBin,
        %    wrap(Header, #mqtt_packet_suback{packet_id = PacketId,
        %                                     qos_table = parse_qos(Rest1, []) }, Rest);
        {?UNSUBSCRIBE, <<FrameBin:Length/binary, Rest/binary>>} ->
            %% 1 = Qos,
            <<PacketId:16/big, Rest1/binary>> = FrameBin,
            Topics = parse_topics(?UNSUBSCRIBE, Rest1, []),
            wrap(Header, #mqtt_packet_unsubscribe{packet_id = PacketId,
                                                  topics    = Topics}, Rest);
        %{?UNSUBACK, <<FrameBin:Length/binary, Rest/binary>>} ->
        %    <<PacketId:16/big>> = FrameBin,
        %    wrap(Header, #mqtt_packet_unsuback { packet_id = PacketId }, Rest);
        {?PINGREQ, Rest} ->
            Length = 0,
            wrap(Header, Rest);
        %{?PINGRESP, Rest} ->
        %    Length = 0,
        %    wrap(Header, Rest);
        {?DISCONNECT, <<FrameBin:Length/binary, Rest/binary>>} ->
            %% Length = 0,
            <<ReturnCode:8, PropsBin/binary>> = FrameBin,
            {Properties, <<>>} = parse_properties(PropsBin),
            wrap(Header, #mqtt_packet_disconnect{return_code = ReturnCode,
                                                 properties  = Properties}, Rest);
        {?AUTH, <<FrameBin:Length/binary, Rest/binary>>} ->
            <<ReturnCode:8, PropBin/binary>> = FrameBin,
            {Properties, <<>>} = parse_properties(PropBin),
            wrap(Header, #mqtt_packet_auth{return_code = ReturnCode,
                                           properties  = Properties}, Rest);
        {_, TooShortBin} ->
            {more, fun(BinMore) ->
                parse_frame(<<TooShortBin/binary, BinMore/binary>>,
                    Header, Length)
            end}
    end.

wrap(Header, Variable, Payload, Rest) ->
    {ok, #mqtt_packet{header = Header, variable = Variable, payload = Payload}, Rest}.
wrap(Header, Variable, Rest) ->
    {ok, #mqtt_packet{header = Header, variable = Variable}, Rest}.
wrap(Header, Rest) ->
    {ok, #mqtt_packet{header = Header}, Rest}.

parse_properties(Bin) ->
    {Len, Bin1} = parse_variable_byte_integer(Bin),
    <<PropBin:Len/binary, Rest/binary>> = Bin1,
    {parse_property(PropBin, []), Rest}.

parse_property(<<>>, Props) ->
    lists:reverse(Props);
parse_property(<<16#01, Val:8, Rest/binary>>, Props) ->
    parse_property(Rest, [{'PAYLOAD_FORMAT', Val} | Props]);
parse_property(<<16#02, Val:32, Rest/binary>>, Props) ->
    parse_property(Rest, [{'PUBLICATION_EXPIRY', Val} | Props]);
parse_property(<<16#08, Bin/binary>>, Props) ->
    {Val, Rest} = parse_utf(Bin),
    parse_property(Rest, [{'REPLY_TOPIC', Val} | Props]);
parse_property(<<16#09, Bin/binary>>, Props) ->
    {Val, Rest} = parse_bin(Bin),
    parse_property(Rest, [{'CORRELATION_DATA', Val} | Props]);
parse_property(<<16#0B, Bin/binary>>, Props) ->
    {Val, Rest} = parse_variable_byte_integer(Bin),
    parse_property(Rest, [{'SUBSCRIPTION_IDENTIFIER', Val} | Props]);
parse_property(<<16#11, Val:32, Rest/binary>>, Props) ->
    parse_property(Rest, [{'SESSION_EXPIRY_INTERVAL', Val} | Props]);
parse_property(<<16#12, Bin/binary>>, Props) ->
    {Val, Rest} = parse_utf(Bin),
    parse_property(Rest, [{'ASSIGNED_CLIENT_IDENTIFIER', Val} | Props]);
parse_property(<<16#13, Val:16, Rest/binary>>, Props) ->
    parse_property(Rest, [{'SERVER_KEEP_ALIVE', Val} | Props]);
parse_property(<<16#15, Bin/binary>>, Props) ->
    {Val, Rest} = parse_utf(Bin),
    parse_property(Rest, [{'AUTH_METHOD', Val} | Props]);
parse_property(<<16#16, Bin/binary>>, Props) ->
    {Val, Rest} = parse_bin(Bin),
    parse_property(Rest, [{'AUTH_DATA', Val} | Props]);
parse_property(<<16#17, Val:8, Rest/binary>>, Props) ->
    parse_property(Rest, [{'REQUEST_PROBLEM_INFO', Val} | Props]);
parse_property(<<16#18, Val:32, Rest/binary>>, Props) ->
    parse_property(Rest, [{'WILL_DELAY_INTERVAL', Val} | Props]);
parse_property(<<16#19, Val:8, Rest/binary>>, Props) ->
    parse_property(Rest, [{'REQUEST_REPLY_INFO', Val} | Props]);
parse_property(<<16#1A, Bin/binary>>, Props) ->
    {Val, Rest} = parse_utf(Bin),
    parse_property(Rest, [{'REPLY_INFO', Val} | Props]);
parse_property(<<16#1C, Bin/binary>>, Props) ->
    {Val, Rest} = parse_utf(Bin),
    parse_property(Rest, [{'SERVER_REFERENCE', Val} | Props]);
parse_property(<<16#1F, Bin/binary>>, Props) ->
    {Val, Rest} = parse_utf(Bin),
    parse_property(Rest, [{'REASON_STRING', Val} | Props]);
parse_property(<<16#21, Val:16, Rest/binary>>, Props) ->
    parse_property(Rest, [{'RECEIVE_MAXIMUM', Val} | Props]);
parse_property(<<16#22, Val:16, Rest/binary>>, Props) ->
    parse_property(Rest, [{'TOPIC_ALIAS_MAXIMUM', Val} | Props]);
parse_property(<<16#23, Val:16, Rest/binary>>, Props) ->
    parse_property(Rest, [{'TOPIC_ALIAS', Val} | Props]);
parse_property(<<16#24, Val:8, Rest/binary>>, Props) ->
    parse_property(Rest, [{'MAXIMUM_QOS', Val} | Props]);
parse_property(<<16#25, Rest/binary>>, Props) ->
    parse_property(Rest, ['RETAIN_UNAVAILABLE' | Props]);
parse_property(<<16#26, Bin/binary>>, Props) ->
    {Val, Rest} = parse_utf_pair(Bin),
    parse_property(Rest, [{'USER_PROPERTY', Val} | Props]).

%client function
%parse_qos(<<>>, Acc) ->
%    lists:reverse(Acc);
%parse_qos(<<QoS:8/unsigned, Rest/binary>>, Acc) ->
%    parse_qos(Rest, [QoS | Acc]).
%
parse_variable_byte_integer(<<0:1, I:7, Rest/binary>>) ->
    {I, Rest};
parse_variable_byte_integer(<<1:1, I:7, Rest/binary>>) ->
    parse_variable_byte_integer(Rest, 1, I).

parse_variable_byte_integer(<<0:1, I:7, Rest/binary>>, Multiplier, Value) ->
    {I * Multiplier + Value, Rest};
parse_variable_byte_integer(<<1:1, I:7, Rest/binary>>, Multiplier, Value) ->
    parse_variable_byte_integer(Rest, Multiplier * ?HIGHBIT, Value + Multiplier * I).

parse_topics(_, <<>>, Topics) ->
    lists:reverse(Topics);
parse_topics(?SUBSCRIBE = Sub, Bin, Topics) ->
    {Name, <<_:6, QoS:2, Rest/binary>>} = parse_utf(Bin),
    parse_topics(Sub, Rest, [{Name, QoS}| Topics]);
parse_topics(?UNSUBSCRIBE = Sub, Bin, Topics) ->
    {Name, <<Rest/binary>>} = parse_utf(Bin),
    parse_topics(Sub, Rest, [Name | Topics]).

parse_utf_pair(Bin) ->
    {Key, Bin1} = parse_utf(Bin),
    {Val, Rest} = parse_utf(Bin1),
    {{Key, Val}, Rest}.

parse_utf(Bin, 0) ->
    {undefined, Bin};
parse_utf(Bin, _) ->
    parse_utf(Bin).

parse_utf(<<Len:16/big, Str:Len/binary, Rest/binary>>) ->
    {Str, Rest}.

parse_msg(Bin, 0) ->
    {undefined, Bin};
parse_msg(<<Len:16/big, Msg:Len/binary, Rest/binary>>, _) ->
    {Msg, Rest}.

parse_bin(<<Len:16/big, Bin:Len/binary, Rest/binary>>) ->
    {Bin, Rest}.

bool(0) -> false;
bool(1) -> true.

protocol_name_approved(Ver, Name) ->
    lists:member({Ver, Name}, ?PROTOCOL_NAMES).

%% Fix Issue#575
fixqos(?PUBREL, 0)      -> 1;
fixqos(?SUBSCRIBE, 0)   -> 1;
fixqos(?UNSUBSCRIBE, 0) -> 1;
fixqos(_Type, QoS)      -> QoS.

