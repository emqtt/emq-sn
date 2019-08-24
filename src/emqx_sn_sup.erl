%%--------------------------------------------------------------------
%% Copyright (c) 2019 EMQ Technologies Co., Ltd. All Rights Reserved.
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

-module(emqx_sn_sup).

-behaviour(supervisor).

-export([ start_link/2
        , init/1
        ]).

start_link(Port, GwId) ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, [Port, GwId]).

init([Port, GwId]) ->
    Registry = #{id       => emqx_sn_registry,
                 start    => {emqx_sn_registry, start_link, []},
                 restart  => permanent,
                 shutdown => 5000,
                 type     => worker,
                 modules  => [emqx_sn_registry]},
    GwSup = #{id       => emqx_sn_gateway_sup,
              start    => {emqx_sn_gateway_sup, start_link, [GwId]},
              restart  => permanent,
              shutdown => infinity,
              type     => supervisor,
              modules  => [emqx_sn_gateway_sup]},
    MFA = {emqx_sn_gateway_sup, start_gateway, []},
    UdpSrv = #{id       => emqx_sn_udp_server,
               start    => {esockd_udp, server, [mqtt_sn, Port, [], MFA]},
               restart  => permanent,
               shutdown => 5000,
               type     => worker,
               modules  => [esockd_udp]},
    Broadcast = #{id       => emqx_sn_broadcast,
                  start    => {emqx_sn_broadcast, start_link, [GwId, Port]},
                  restart  => permanent,
                  shutdown => brutal_kill,
                  type     => worker,
                  modules  => [emqx_sn_broadcast]},
    {ok, {{one_for_all, 10, 3600}, [Registry, GwSup, UdpSrv, Broadcast]}}.

