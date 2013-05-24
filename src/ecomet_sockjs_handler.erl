%%%
%%% ecomet_sockjs_handler: handler to create sockjs children
%%%
%%% Copyright (c) 2011 Megaplan Ltd. (Russia)
%%%
%%% Permission is hereby granted, free of charge, to any person obtaining a copy
%%% of this software and associated documentation files (the "Software"),
%%% to deal in the Software without restriction, including without limitation
%%% the rights to use, copy, modify, merge, publish, distribute, sublicense,
%%% and/or sell copies of the Software, and to permit persons to whom
%%% the Software is furnished to do so, subject to the following conditions:
%%%
%%% The above copyright notice and this permission notice shall be included
%%% in all copies or substantial portions of the Software.
%%%
%%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
%%% EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
%%% MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
%%% IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
%%% CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
%%% TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
%%% SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
%%%
%%% @author arkdro <arkdro@gmail.com>
%%% @since 2012-01-17 18:39
%%% @license MIT
%%% @doc handler that starts sockjs app and gets requests to create children
%%% to serve new sockjs requests
%%%

-module(ecomet_sockjs_handler).

%%%----------------------------------------------------------------------------
%%% Exports
%%%----------------------------------------------------------------------------

-export([
         start/1,
         stop/0,
         init/3,
         handle/2,
         terminate/2
        ]).

%%%----------------------------------------------------------------------------
%%% Includes
%%%----------------------------------------------------------------------------

-include("ecomet_server.hrl").

%%%----------------------------------------------------------------------------
%%% API
%%%----------------------------------------------------------------------------
%%
%% @doc starts configured backend - currently cowboy only
%% @since 2012-01-17 18:39
%%
-spec start(#csr{}) -> ok.

start(#csr{sockjs_config=undefined}) ->
    mpln_p_debug:er({?MODULE, ?LINE, 'init, sockjs undefined'}),
    ok;

start(#csr{sockjs_config=Sc} = C) ->
    mpln_p_debug:pr({?MODULE, 'init', ?LINE}, C#csr.debug, run, 1),
    Port = proplists:get_value(port, Sc),
    Nb_acc = proplists:get_value(nb_acceptors, Sc, 100),
    Max_conn = proplists:get_value(max_connections, Sc, 1024),
    {Base, Base_p} = prepare_base(Sc),
    Trans_opt = [{port, Port}, {max_connections, Max_conn}],
    prepare_cowboy(C, Base, Base_p, Nb_acc, Trans_opt),
    mpln_p_debug:pr({?MODULE, 'init done', ?LINE, Port}, C#csr.debug, run, 2),
    ok.

stop() ->
    application:stop(cowboy),
    application:stop(sockjs).

%%%----------------------------------------------------------------------------
%%% Callbacks for cowboy
%%%----------------------------------------------------------------------------

init({_Any, http}, Req, []) ->
    mpln_p_debug:ir({?MODULE, ?LINE, init_http, _Any, Req}),
    {ok, Req, []}.

handle(Req, State) ->
    {Path, Req1} = cowboy_http_req:path(Req),
    error_logger:info_report({?MODULE, 'handle1', ?LINE, Path, Req1, State}),
    case Path of
        [<<"ecomet.html">> = H] ->
            %% FIXME: this branch is for debug only
            error_logger:info_report({?MODULE, 'handle1 ecomet', ?LINE}),
            static(Req1, H, State);
        _ ->
            error_logger:info_report({?MODULE, 'handle1 other', ?LINE}),
            {ok, Req2} = cowboy_http_req:reply(404, [],
                         <<"404 - Nothing here (via sockjs-erlang fallback)\n">>, Req1),
            {ok, Req2, State}
    end.

terminate(_Req, _State) ->
    error_logger:info_report({?MODULE, 'terminate', ?LINE, _Req, _State}),
    ok.

%%%----------------------------------------------------------------------------
%%% Internal functions
%%%----------------------------------------------------------------------------
%%
%% @doc handler for static requests. Used for debug only.
%%
static(Req, Path, State) ->
    error_logger:info_report({?MODULE, 'static', ?LINE, Path, State, Req}),
    LocalPath = filename:join([module_path(), "priv/www", Path]),
    case file:read_file(LocalPath) of
        {ok, Contents} ->
            error_logger:info_report({?MODULE, 'static ok', ?LINE, LocalPath}),
            {ok, Req2} = cowboy_http_req:reply(200, [{<<"Content-Type">>,
                "text/html"}], Contents, Req),
            {ok, Req2, State};
        {error, Reason} ->
            error_logger:info_report({?MODULE, 'static error', ?LINE, LocalPath, Reason}),
            {ok, Req2} = cowboy_http_req:reply(404, [],
                         <<"404 - Nothing here (via sockjs-erlang fallback)\n">>, Req),
            {ok, Req2, State}
    end.

module_path() ->
    {file, Here} = code:is_loaded(?MODULE),
    filename:dirname(filename:dirname(Here)).

%%-----------------------------------------------------------------------------
%%
%% @doc handler of sockjs messages: init, recv, closed.
%%
bcast(Conn, {recv, <<"\"echo\"">> = Data}, _St) ->
    sockjs:send(Data, Conn);

bcast(Conn, {recv, Data}, St) ->
    %erlang:display({now(), recv, Data}),
    Sid = Conn,
    erpher_et:trace_me(50, ?MODULE, ecomet_server, 'bcast recv', Data),
    ecomet_server:sjs_msg(Sid, Conn, Data),
    {ok, St};

bcast(Conn, init, St) ->
    Sid = Conn,
    erpher_et:trace_me(50, ?MODULE, ecomet_server, 'bcast init'),
    ecomet_server:sjs_add(Sid, Conn),
    {ok, St};

bcast(Conn, closed, St) ->
    Sid = Conn,
    erpher_et:trace_me(50, ?MODULE, ecomet_server, 'bcast closed'),
    ecomet_server:sjs_del(Sid, Conn),
    {ok, St};

bcast(_Conn, _Data, St) ->
    mpln_p_debug:er({?MODULE, ?LINE, 'bcast unknown', _Conn, _Data}),
    {ok, St}.


send(Conn, Data) ->
    Json = mochijson2:encode(Data),
    Msg = iolist_to_binary(Json),
    sockjs:send(Msg, Conn).

%%-----------------------------------------------------------------------------
%%
%% @doc creates base path from the configured tag
%%
-spec prepare_base(list()) -> {binary(), binary()}.

prepare_base(List) ->
    Tag = proplists:get_value(tag, List),
    Base = mpln_misc_web:make_binary(Tag),
    Base_p = << <<"/">>/binary, Base/binary>>,
    {Base, Base_p}.

%%-----------------------------------------------------------------------------
%%
%% @doc prepares cowboy
%%
-spec prepare_cowboy(#csr{}, binary(), binary(), non_neg_integer(), list()) ->
                            ok.

prepare_cowboy(C, Base, Base_p, Nb_acc, Trans_opts) ->
    Flogger = fun(_Service, Req, _Type) ->
                      Req
                      %flogger(C, _Service, Req, _Type)
              end,
    StateEcho = sockjs_handler:init_state(
                  Base_p,
                  fun bcast/3,
                  state,
                  [{cookie_needed, true},
                   {response_limit, 4096},
                   {logger, Flogger}
                  ]),
    VRoutes = [{[Base, '...'], sockjs_cowboy_handler, StateEcho},
               {'_', ?MODULE, []}],
    Routes = [{'_',  VRoutes}], % any vhost

    cowboy:start_listener(http, Nb_acc,
                          cowboy_tcp_transport, Trans_opts,
                          cowboy_http_protocol, [{dispatch, Routes}]).

%%-----------------------------------------------------------------------------
flogger(C, _Service, Req, _Type) ->
    {LongPath, Req1} = sockjs_http:path(Req),
    {Method, Req2}   = sockjs_http:method(Req1),
    mpln_p_debug:pr({?MODULE, 'flogger', ?LINE, _Type, Method, LongPath}, C#csr.debug, http, 3),
    mpln_p_debug:pr({?MODULE, 'flogger', ?LINE, _Service, Req}, C#csr.debug, http, 6),
    Req2.

%%-----------------------------------------------------------------------------
