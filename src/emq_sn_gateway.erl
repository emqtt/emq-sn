%%--------------------------------------------------------------------
%% Copyright (c) 2016 Feng Lee <feng@emqtt.io>. All Rights Reserved.
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

-module(emq_sn_gateway).

-author("Feng Lee <feng@emqtt.io>").

-behaviour(gen_fsm).

-include("emq_sn.hrl").

-include_lib("emqttd/include/emqttd_protocol.hrl").

%% API.
-export([start_link/2]).

%% SUB/UNSUB Asynchronously. Called by plugins.
-export([subscribe/2, unsubscribe/2]).

%% gen_fsm.

-export([idle/2, idle/3, wait_for_will_topic/2, wait_for_will_topic/3,
         wait_for_will_msg/2, wait_for_will_msg/3, connected/2, connected/3]).

-export([init/1, handle_event/3, handle_sync_event/4, handle_info/3,
         terminate/3, code_change/4]).

-record(state, {gwid, gwinfo = <<>>, sock, peer, protocol, client_id, keepalive, connpkt}).

-define(LOG(Level, Format, Args, State),
            lager:Level("MQTT-SN(~s): " ++ Format,
                        [esockd_net:format(State#state.peer) | Args])).

-spec(start_link(inet:socket(), {inet:ip_address(), inet:port()}) -> {ok, pid()}).
start_link(Sock, Peer) ->
    gen_fsm:start_link(?MODULE, [Sock, Peer], []).

%% TODO:

subscribe(GwPid, TopicTable) ->
    gen_fsm:send_event(GwPid, {subscribe, TopicTable}).

unsubscribe(GwPid, Topics) ->
    gen_fsm:send_event(GwPid, {unsubscribe, Topics}).

%% TODO:

%% gen_fsm.
init([Sock, Peer]) ->
    put(sn_gw, Peer), %%TODO:
    State = #state{gwid = 1, sock = Sock, peer = Peer},
    SendFun = fun(Packet) -> send_message(transform(Packet), State) end,
    PktOpts = [{max_clientid_len, 24}, {max_packet_size, 256}],
    ProtoState = emqttd_protocol:init(Peer, SendFun, PktOpts),
    {ok, idle, State#state{protocol = ProtoState}, 3000}.

idle(timeout, StateData) ->
    {stop, idle_timeout, StateData};

idle(?SN_SEARCHGW_MSG(_Radius), StateData = #state{gwid = GwId, gwinfo = GwInfo}) ->
    send_message(?SN_GWINFO_MSG(GwId, GwInfo), StateData),
    {next_state, idle, StateData};

idle(?SN_CONNECT_MSG(Flags, _ProtoId, Duration, ClientId), StateData = #state{protocol = Proto}) ->
    %%TODO:
    #mqtt_sn_flags{will = Will, clean_session = CleanSession} = Flags,
    ConnPkt = #mqtt_packet_connect{client_id  = ClientId,
                                   clean_sess = CleanSession,
                                   keep_alive = Duration},
    case Will of
        true  ->
            send_message(?SN_WILLTOPICREQ_MSG(), StateData#state{connpkt = ConnPkt}),
            {next_state, wait_for_will_topic, StateData#state{connpkt = ConnPkt, client_id = ClientId}};
        false ->
            case emqttd_protocol:received(?CONNECT_PACKET(ConnPkt), Proto) of
                {ok, Proto1}           -> next_state(connected, StateData#state{client_id = ClientId, protocol = Proto1});
                {error, Error}         -> shutdown(Error, StateData);
                {error, Error, Proto1} -> shutdown(Error, StateData#state{protocol = Proto1});
                {stop, Reason, Proto1} -> stop(Reason, StateData#state{protocol = Proto1})
            end
    end;

idle(Event, StateData) ->
    %%TODO:...
    ?LOG(error, "UNEXPECTED Event: ~p", [Event], StateData),
    {next_state, idle, StateData}.

wait_for_will_topic(?SN_WILLTOPIC_MSG(Flags, Topic), StateData = #state{connpkt = ConnPkt}) ->
    #mqtt_sn_flags{qos = Qos, retain = Retain} = Flags,
    ConnPkt1 = ConnPkt#mqtt_packet_connect{will_retain = Retain,
                                           will_qos    = Qos,
                                           will_topic  = Topic,
                                           will_flag   = true},
    send_message(?SN_WILLMSGREQ_MSG(), StateData),
    {next_state, wait_for_will_msg, StateData#state{connpkt = ConnPkt1}};

wait_for_will_topic(_Event, StateData) ->
    %%TODO: LOG error
    {next_state, wait_for_will_topic, StateData}.

wait_for_will_msg(?SN_WILLMSG_MSG(Msg), StateData = #state{protocol = Proto, connpkt = ConnPkt}) ->
    %%TODO: protocol connect
    ConnPkt1 = ConnPkt#mqtt_packet_connect{will_msg = Msg},
    case emqttd_protocol:received(?CONNECT_PACKET(ConnPkt1), Proto) of
        {ok, Proto1}           -> next_state(connected, StateData#state{protocol = Proto1});
        {error, Error}         -> shutdown(Error, StateData);
        {error, Error, Proto1} -> shutdown(Error, StateData#state{protocol = Proto1});
        {stop, Reason, Proto1} -> stop(Reason, StateData#state{protocol = Proto1})
    end;

wait_for_will_msg(Event, StateData) ->
    ?LOG(error, "UNEXPECTED Event: ~p", [Event], StateData),
    {next_state, wait_for_will_msg, StateData}.

connected(?SN_REGISTER_MSG(TopicId, MsgId, TopicName), StateData = #state{client_id = ClientId}) ->
    emq_sn_registry:register_topic(ClientId, TopicId, TopicName),
    send_message(?SN_REGACK_MSG(TopicId, MsgId, 0), StateData),
    {next_state, connected, StateData};

connected(?SN_PUBLISH_MSG(Flags, TopicId, MsgId, Data), StateData = #state{client_id = ClientId, protocol = Proto}) ->
    #mqtt_sn_flags{dup = Dup, qos = Qos, retain = Retain, topic_id_type = TopicIdType} = Flags,
    case topicid_to_topicname(TopicIdType, TopicId, ClientId) of
        undefined ->
            send_message(?SN_PUBACK_MSG(TopicId, MsgId, ?SN_RC_INVALID_TOPIC_ID), StateData);
        TopicName -> 
            Publish = #mqtt_packet{header   = #mqtt_packet_header{type = ?PUBLISH, dup = Dup, qos = Qos, retain = Retain},
                                   variable = #mqtt_packet_publish{topic_name = TopicName, packet_id = MsgId},
                                   payload  = Data},
            case emqttd_protocol:received(Publish, Proto) of
                {ok, Proto1}           -> next_state(connected, StateData#state{protocol = Proto1});
                {error, Error}         -> shutdown(Error, StateData);
                {error, Error, Proto1} -> shutdown(Error, StateData#state{protocol = Proto1});
                {stop, Reason, Proto1} -> stop(Reason, StateData#state{protocol = Proto1})
            end
    end;

connected(?SN_PUBACK_MSG(_TopicId, MsgId, _ReturnCode), StateData = #state{protocol = Proto}) ->
    case emqttd_protocol:received(?PUBACK_PACKET(mqttsn_to_mqtt(?PUBACK), MsgId), Proto) of
        {ok, Proto1}           -> next_state(connected, StateData#state{protocol = Proto1});
        {error, Error}         -> shutdown(Error, StateData);
        {error, Error, Proto1} -> shutdown(Error, StateData#state{protocol = Proto1});
        {stop, Reason, Proto1} -> stop(Reason, StateData#state{protocol = Proto1})
    end;

connected(?SN_PUBREC_MSG(PubRec, MsgId), StateData = #state{protocol = Proto})
    when PubRec == ?SN_PUBREC; PubRec == ?SN_PUBREL; PubRec == ?SN_PUBCOMP ->
    case emqttd_protocol:received(?PUBACK_PACKET(mqttsn_to_mqtt(PubRec), MsgId), Proto) of
        {ok, Proto1}           -> next_state(connected, StateData#state{protocol = Proto1});
        {error, Error}         -> shutdown(Error, StateData);
        {error, Error, Proto1} -> shutdown(Error, StateData#state{protocol = Proto1});
        {stop, Reason, Proto1} -> stop(Reason, StateData#state{protocol = Proto1})
    end;

connected(?SN_SUBSCRIBE_MSG(Flags, MsgId, TopicId), StateData = #state{client_id = ClientId, protocol = Proto}) ->
    #mqtt_sn_flags{qos = Qos, topic_id_type = TopicIdType} = Flags,
    case topicid_to_topicname(TopicIdType, TopicId, ClientId) of
        undefined ->
            NewFlag = <<0:1, Qos:2, 0:5>>,
            send_message(?SN_SUBACK_MSG(NewFlag, TopicId, MsgId, ?SN_RC_INVALID_TOPIC_ID), StateData);
        TopicName ->
            case emqttd_protocol:received(?SUBSCRIBE_PACKET(MsgId, [{TopicName, Qos}]), Proto) of
                {ok, Proto1}           -> next_state(connected, StateData#state{protocol = Proto1});
                {error, Error}         -> shutdown(Error, StateData);
                {error, Error, Proto1} -> shutdown(Error, StateData#state{protocol = Proto1});
                {stop, Reason, Proto1} -> stop(Reason, StateData#state{protocol = Proto1})
            end
    end;

connected(?SN_UNSUBSCRIBE_MSG(Flags, MsgId, TopicId), StateData = #state{client_id = ClientId, protocol = Proto}) ->
    #mqtt_sn_flags{topic_id_type = TopicIdType} = Flags,
    case topicid_to_topicname(TopicIdType, TopicId, ClientId) of
        undefined -> stop(protocol_bad_topicidtype, StateData#state{protocol = Proto});  %% UNSUBACK has no ReturnCode
        TopicName ->
            case emqttd_protocol:received(?UNSUBSCRIBE_PACKET(MsgId, [TopicName]), Proto) of
                {ok, Proto1}           -> next_state(connected, StateData#state{protocol = Proto1});
                {error, Error}         -> shutdown(Error, StateData);
                {error, Error, Proto1} -> shutdown(Error, StateData#state{protocol = Proto1});
                {stop, Reason, Proto1} -> stop(Reason, StateData#state{protocol = Proto1})
            end
    end;

connected(?SN_PINGREQ_MSG(_ClientId), StateData) ->
    send_message(?SN_PINGRESP_MSG(), StateData),
    next_state(connected, StateData);

connected(?SN_DISCONNECT_MSG(_Duration), StateData = #state{protocol = Proto}) ->
    {stop, Reason, Proto1} = emqttd_protocol:received(?PACKET(?DISCONNECT), Proto),
    stop(Reason, StateData#state{protocol = Proto1});

% connected(?SN_WILLTOPICUPD_MSG(Flags, Topic), StateData = #state{connpkt = ConnPkt, protocol = Proto}) ->
%     #mqtt_sn_flags{qos = Qos, retain = Retain} = Flags,
%     ConnPkt1 = ConnPkt#mqtt_packet_connect{will_retain = Retain,
%                                            will_qos    = Qos,
%                                            will_topic  = Topic},
%     send_message(?SN_WILLTOPICRESP_MSG(0), StateData),
%     % Proto1 = will_topic_update(ConnPkt1, Proto),
%     {next_state, connected, StateData#state{protocol = Proto}};

% connected(?SN_WILLMSGUPD_MSG(Msg), StateData = #state{connpkt = ConnPkt, protocol = Proto}) ->
%     ConnPkt1 = ConnPkt#mqtt_packet_connect{will_msg = Msg},
%     send_message(?SN_WILLMSGRESP_MSG(0), StateData),
%     % Proto1 = will_msg_update(ConnPkt1, Proto),
%     {next_state, connected, StateData#state{protocol = Proto}};

connected(Event, StateData) ->
    ?LOG(error, "UNEXPECTED Event: ~p", [Event], StateData),
    {next_state, connected, StateData}.

handle_event(Event, StateName, StateData) ->
    ?LOG(error, "UNEXPECTED Event: ~p", [Event], StateData),
    {next_state, StateName, StateData}.

idle(Event, _From, StateData) ->
    ?LOG(error, "UNEXPECTED Event: ~p", [Event], StateData),
    {reply, ignored, idle, StateData}.

wait_for_will_topic(Event, _From, StateData) ->
    ?LOG(error, "UNEXPECTED Event: ~p", [Event], StateData),
    {reply, ignored, wait_for_will_topic, StateData}.

wait_for_will_msg(Event, _From, StateData) ->
    ?LOG(error, "UNEXPECTED Event: ~p", [Event], StateData),
    {reply, ignored, wait_for_will_msg, StateData}.

connected(Event, _From, StateData) ->
    ?LOG(error, "UNEXPECTED Event: ~p", [Event], StateData),
    {reply, ignored, state_name, StateData}.

handle_sync_event(Event, _From, StateName, StateData) ->
    ?LOG(error, "UNEXPECTED SYNC Event: ~p", [Event], StateData),
    {reply, ignored, StateName, StateData}.

handle_info({datagram, _From, Data}, StateName, StateData) ->
    {ok, Msg} = emq_sn_message:parse(Data),
    ?LOG(info, "RECV ~p", [Msg], StateData),
    ?MODULE:StateName(Msg, StateData); %% cool?

%% Asynchronous SUBACK
handle_info({suback, MsgId, [GrantedQos]}, StateName, StateData) ->
    Flags = #mqtt_sn_flags{qos = GrantedQos},
    send_message(?SN_SUBACK_MSG(Flags, 1, MsgId, 0), StateData),
    next_state(StateName, StateData);

handle_info({deliver, Msg}, StateName, StateData = #state{client_id = ClientId}) ->
    #mqtt_packet{header   = #mqtt_packet_header{type = ?PUBLISH, dup = Dup, qos = Qos, retain = Retain},
                  variable = #mqtt_packet_publish{topic_name = TopicName, packet_id = MsgId},
                  payload  = Payload} = emqttd_message:to_packet(Msg),
    case emq_sn_registry:lookup_topic_id(ClientId, TopicName) of
        undefined -> 
            case byte_size(TopicName) of
                2 -> send_publish(Dup, Qos, Retain, 2, TopicName, MsgId, Payload, StateData);  % use short topic name
                _ -> ?LOG(error, "Before subscribing, please register topic: ~p", [TopicName], StateData)
            end;
        TopicId -> 
            send_publish(Dup, Qos, Retain, 1, TopicId, MsgId, Payload, StateData)   % use pre-defined topic id
    end,
    next_state(StateName, StateData);

handle_info({redeliver, {?PUBREL, MsgId}}, StateName, StateData) ->
    send_message(?SN_PUBREC_MSG(?SN_PUBREL, MsgId), StateData),
    next_state(StateName, StateData);

handle_info({keepalive, start, Interval}, StateName, StateData = #state{sock = Sock}) ->
    ?LOG(debug, "Keepalive at the interval of ~p", [Interval], StateData),
    StatFun = fun() ->
                case inet:getstat(Sock, [recv_oct]) of
                    {ok, [{recv_oct, RecvOct}]} -> {ok, RecvOct};
                    {error, Error}              -> {error, Error}
                end
             end,
    KeepAlive = emqttd_keepalive:start(StatFun, Interval, {keepalive, check}),
    next_state(StateName, StateData#state{keepalive = KeepAlive});

handle_info({keepalive, check}, StateName, StateData = #state{keepalive = KeepAlive}) ->
    case emqttd_keepalive:check(KeepAlive) of
        {ok, KeepAlive1} ->
            next_state(StateName, StateData#state{keepalive = KeepAlive1});
        {error, timeout} ->
            ?LOG(debug, "Keepalive timeout", [], StateData),
            shutdown(keepalive_timeout, StateData);
        {error, Error} ->
            ?LOG(warning, "Keepalive error - ~p", [Error], StateData),
            shutdown(Error, StateData)
    end;

handle_info(Info, StateName, StateData) ->
    ?LOG(error, "UNEXPECTED INFO: ~p", [Info], StateData),
    {next_state, StateName, StateData}.

terminate(Reason, _StateName, _StateData = #state{client_id = ClientId, keepalive = KeepAlive, protocol = Proto}) ->
    emq_sn_registry:unregister_topic(ClientId),
    emqttd_keepalive:cancel(KeepAlive),
    case {Proto, Reason} of
        {undefined, _} ->
            ok;
        {_, {shutdown, Error}} ->
            emqttd_protocol:shutdown(Error, Proto);
        {_, Reason} ->
            emqttd_protocol:shutdown(Reason, Proto)
    end.

code_change(_OldVsn, StateName, StateData, _Extra) ->
    {ok, StateName, StateData}.

transform(?CONNACK_PACKET(0)) ->
    ?SN_CONNACK_MSG(0);

transform(?CONNACK_PACKET(_ReturnCode)) ->
    ?SN_CONNACK_MSG(?SN_RC_CONGESTION);

transform(?PUBACK_PACKET(?PUBACK, MsgId)) ->
    ?SN_PUBACK_MSG(1, MsgId, 0);

transform(?PUBACK_PACKET(?PUBREC, MsgId)) ->
    ?SN_PUBREC_MSG(?SN_PUBREC, MsgId);

transform(?PUBACK_PACKET(?PUBREL, MsgId)) ->
    ?SN_PUBREC_MSG(?SN_PUBREL, MsgId);

transform(?PUBACK_PACKET(?PUBCOMP, MsgId)) ->
    ?SN_PUBREC_MSG(?SN_PUBCOMP, MsgId);

transform(?UNSUBACK_PACKET(MsgId))->
    ?SN_UNSUBACK_MSG(MsgId).

send_publish(Dup, Qos, Retain, TopicIdType, TopicName, MsgId, Payload, StateData) when is_binary(TopicName) ->
    <<TopicId:16>> = TopicName,
    send_publish(Dup, Qos, Retain, TopicIdType, TopicId, MsgId, Payload, StateData);
send_publish(Dup, Qos, Retain, TopicIdType, TopicId, MsgId, Payload, StateData) ->
    MsgId1 = case Qos > 0 of
                 true -> MsgId;
                 false -> 0
             end,
    Flags = #mqtt_sn_flags{dup = Dup, qos = Qos, retain = Retain, topic_id_type = TopicIdType},
    Data = ?SN_PUBLISH_MSG(Flags, TopicId, MsgId1, Payload),
    send_message(Data, StateData).


send_message(Msg, StateData = #state{sock = Sock, peer = {Host, Port}}) ->
    ?LOG(debug, "SEND ~p~n", [Msg], StateData),
    gen_udp:send(Sock, Host, Port, emq_sn_message:serialize(Msg)).

next_state(StateName, StateData) ->
    {next_state, StateName, StateData, hibernate}.

shutdown(Error, StateData) ->
    {stop, {shutdown, Error}, StateData}.

stop(Reason, StateData) ->
    {stop, Reason, StateData}.

mqttsn_to_mqtt(?SN_PUBACK) -> ?PUBACK;
mqttsn_to_mqtt(?SN_PUBREC) -> ?PUBREC;
mqttsn_to_mqtt(?SN_PUBREL) -> ?PUBREL;
mqttsn_to_mqtt(?SN_PUBCOMP) -> ?PUBCOMP.


topicid_to_topicname(TopicType, TopicId, _ClientId) when TopicType == 0 ->
    TopicId;
topicid_to_topicname(TopicType, TopicId, ClientId) when TopicType == 1 ->
    emq_sn_registry:lookup_topic(ClientId, TopicId);
topicid_to_topicname(TopicType, TopicId, _ClientId) when TopicType == 2 ->
    case is_binary(TopicId) of
        true -> TopicId;
        false -> <<TopicId:16>>
    end;
topicid_to_topicname(_TopicType, _TopicId, _ClientId) ->
    undefined.


