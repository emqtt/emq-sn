%%%-------------------------------------------------------------------
%%% Copyright (c) 2013-2017 EMQ Enterprise, Inc. (http://emqtt.io)
%%%
%%% Licensed under the Apache License, Version 2.0 (the "License");
%%% you may not use this file except in compliance with the License.
%%% You may obtain a copy of the License at
%%%
%%%     http://www.apache.org/licenses/LICENSE-2.0
%%%
%%% Unless required by applicable law or agreed to in writing, software
%%% distributed under the License is distributed on an "AS IS" BASIS,
%%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%% See the License for the specific language governing permissions and
%%% limitations under the License.
%%%-------------------------------------------------------------------

-module(emq_sn_normal_topics).

-author("Feng Lee <feng@emqtt.io>").

-behaviour(gen_server).

-define(LOG(Level, Format, Args),
    lager:Level("MQTT-SN(registry): " ++ Format, Args)).

%% API.
-export([start_link/0, stop/0]).

-export([register_topic/2, lookup_topic/2, unregister_topic/1, lookup_topic_id/2, wildcard/1]).

%% gen_server.
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {}).

%%--------------------------------------------------------------------
%% API
%%--------------------------------------------------------------------

-spec(start_link() -> {ok, pid()}).
start_link() ->
	gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec(stop() -> ok).
stop() ->
    gen_server:call(?MODULE, stop).

-spec(register_topic(binary(), binary()) -> integer()).
register_topic(ClientId, TopicName) ->
    gen_server:call(?MODULE, {register, ClientId, TopicName}).

-spec(lookup_topic(binary(), pos_integer()) -> undefined | binary()).
lookup_topic(ClientId, TopicId) ->
    try ets:lookup_element(sn_topic_name, {ClientId, TopicId}, 2)
    catch
        error:badarg -> undefined
    end.

-spec(lookup_topic_id(binary(), binary) -> undefined | pos_integer()).
lookup_topic_id(ClientId,TopicName) ->
    try ets:lookup_element(sn_topic_id, {ClientId, TopicName}, 2)
    catch
        error:badarg -> undefined
    end.

-spec(unregister_topic(binary()) -> ok).
unregister_topic(ClientId) ->
    gen_server:call(?MODULE, {unregister, ClientId}).

%%--------------------------------------------------------------------
%% gen_server Callbacks
%%--------------------------------------------------------------------

init([]) ->
    %% ClientId -> [TopicId]
    ets:new(sn_topic, [bag, named_table, protected]),
    %% {ClientId, TopicId} -> TopicName
    ets:new(sn_topic_name, [set, named_table, protected]),
    %% {ClientId, TopicName} ->TopicId 
    ets:new(sn_topic_id, [set, named_table, protected]),

	{ok, #state{}}.

handle_call({register, ClientId, TopicName}, _From, State) ->
    case wildcard((TopicName)) of
        false ->
            case get_registered_id(ClientId, TopicName) of
                undefined ->  % this topic has never been registered
                    {reply, register_new_topic(ClientId, TopicName), State, hibernate};
                ExistTopicId ->
                    {reply, ExistTopicId, State, hibernate}
            end;
        true ->
            %% TopicId: in case of “accepted” the value that will be used as topic id by the gateway when sending PUBLISH
            %% messages to the client (not relevant in case of subscriptions to a short topic name or to a topic name which
            %% contains wildcard characters)
            {reply, wildcard_topic, State, hibernate}
    end;

handle_call({unregister, ClientId}, _From, State) ->
    lists:foreach(
        fun({_, TopicId}) ->
            [{_, TopicName}] = ets:lookup(sn_topic_name, {ClientId, TopicId}),
            ets:delete(sn_topic_name, {ClientId, TopicId}),
            ets:delete(sn_topic_id, {ClientId, TopicName})
        end, ets:lookup(sn_topic, ClientId)),
    ets:delete(sn_topic, ClientId),
    {reply, ok, State, hibernate};

handle_call(stop, _From, State) ->
    {stop, normal, ok, State};

handle_call(_Request, _From, State) ->
	{reply, ignored, State}.

handle_cast(_Msg, State) ->
	{noreply, State, hibernate}.

handle_info(_Info, State) ->
	{noreply, State, hibernate}.

terminate(_Reason, _State) ->
	ok.

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.



%%--------------------------------------------------------------------
%% Internal Functions
%%--------------------------------------------------------------------

get_registered_id(ClientId, TopicName) ->
    case ets:lookup(sn_topic_id, {ClientId, TopicName}) of
        [] ->  % this topic has never been registered
            undefined;
        [{{ClientId, TopicName}, ExistTopicId}] ->  % this topic has been registered
            ExistTopicId
    end.

register_new_topic(ClientId, TopicName) ->
    %% The values “0x0000” and “0xFFFF” are reserved and therefore should not be used.
    NewTopicId = emq_sn_predefined_topics:get_max_predef_topic_id() + length(ets:lookup(sn_topic, ClientId)) + 1,
    case NewTopicId < 16#FFFF of
        true ->  % this id is new
            ets:insert(sn_topic, {ClientId, NewTopicId}),
            ets:insert(sn_topic_name, {{ClientId, NewTopicId}, TopicName}),
            ets:insert(sn_topic_id, {{ClientId, TopicName}, NewTopicId}),
            NewTopicId;
        false -> % id is full
            undefined
    end.

-spec(wildcard(binary()|list()) -> true | false).
wildcard(Topic) when is_binary(Topic) ->
    TopicString = binary_to_list(Topic),
    wildcard(TopicString);
wildcard([]) ->
    false;
wildcard([$#|_]) ->
    true;
wildcard([$+|_]) ->
    true;
wildcard([_H|T]) ->
    wildcard(T).
