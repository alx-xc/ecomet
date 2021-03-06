-module(ecomet_server_sup).
-behaviour(supervisor).
-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ecomet_server_sup}, ecomet_server_sup, []).

init(_Args) ->
    Csup = {
        ecomet_conn_sup, {ecomet_conn_sup, start_link, []},
        permanent, infinity, supervisor, [ecomet_conn_sup]
    },
    Auth = {
        ecomet_auth, {ecomet_auth_server, start_link, []},
        permanent, 1000, worker, [ecomet_auth_server]
    },
    Ch = {
        ecomet_srv, {ecomet_server, start_link, []},
        permanent, 1000, worker, [ecomet_server]
    },
    {ok, {{one_for_all, 3, 5},
          [Csup, Auth, Ch]}}.
