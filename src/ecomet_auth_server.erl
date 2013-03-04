%%%
%%% ecomet_auth_server: ecomet auth server
%%%
%%% Copyright (c) 2013 Megaplan Ltd. (Russia)
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
%%% @author alx-xc <alx-xc@yandex.com>
%%% @since 2011-10-14 15:40
%%% @license MIT
%%% @doc authentication server for ecomet connections
%%%

-module(ecomet_auth_server).
-behaviour(gen_server).


%%%----------------------------------------------------------------------------
%%% Exports
%%%----------------------------------------------------------------------------

-export([start/0, start_link/0, stop/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).
-export([code_change/3]).
-export([proceed_http_auth_req/3]).

%%%----------------------------------------------------------------------------
%%% Includes
%%%----------------------------------------------------------------------------

-include("ecomet_nums.hrl").
-include("ecomet_auth.hrl").

%%%----------------------------------------------------------------------------
%%% gen_server callbacks
%%%----------------------------------------------------------------------------
init(_) ->
    Config = ecomet_conf:get_auth_config(),
    Cache = ets:new(ecomet_auth_cache,[set]),
    Timer_gc = erlang:send_after(Config#auth_cnf.cache_gc_interval * 1000, self(), run_gc),
    St = #auth_st{config = Config, cache = Cache, timer_gc = Timer_gc},
    {ok, St}.

%%-----------------------------------------------------------------------------
handle_call(get_config, _From, St) ->
    {reply, St#auth_st.config, St};

handle_call(get_cache, _From, St) ->
    {reply, St#auth_st.cache, St};

handle_call({cache_get, Key}, _From, #auth_st{cache = Cache} = St) ->
    Res = ets:lookup(Cache, Key),
    {reply, Res, St};

handle_call(_N, _From, St) ->
    mpln_p_debug:er({?MODULE, ?LINE, handle_call_unknown, _N}),
    {reply, {error, unknown_request}, St}.

%%-----------------------------------------------------------------------------
handle_cast({cache_set, {Key, Data}}, #auth_st{cache = Cache} = St) ->
    ets:insert(Cache, {Key, Data, timestamp()}),
    {noreply, St};

handle_cast(_N, St) ->
    mpln_p_debug:er({?MODULE, ?LINE, cast_other, _N}),
    {noreply, St}.

%%-----------------------------------------------------------------------------
terminate(_Reason, _St) ->
    mpln_p_debug:er({?MODULE, ?LINE, terminate, _Reason}),
    ok.

%%-----------------------------------------------------------------------------
handle_info(run_gc, St) ->
    St_new = run_gc(St),
    {noreply, St_new};

%% @doc unknown info
handle_info(_N, St) ->
    mpln_p_debug:er({?MODULE, ?LINE, handle_info_unknown,  _N}),
    {noreply, St}.

%%-----------------------------------------------------------------------------
code_change(_Old_vsn, State, _Extra) ->
    {ok, State}.

%%%----------------------------------------------------------------------------
%%% API
%%%----------------------------------------------------------------------------

%%-----------------------------------------------------------------------------
start() ->
    start_link().

%%-----------------------------------------------------------------------------
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%%-----------------------------------------------------------------------------
stop() ->
    gen_server:call(?MODULE, stop).

%%-----------------------------------------------------------------------------
%%
%% @doc creates http request (to perform client's auth on auth server),
%% sends it to a server, returns response
%%
proceed_http_auth_req(Url, Cookie, Host) ->
    Config = gen_server:call(?MODULE, get_config),
    http_auth_cache(Url, Cookie, Host, Config).

%%-----------------------------------------------------------------------------
%% Internal functions
%%-----------------------------------------------------------------------------

timestamp() ->
    {Mega, Seconds, _} = erlang:now(),
    Mega * 1000000 + Seconds.

run_gc(#auth_st{config = Config, cache = Cache, timer_gc = Timer_gc} = St) ->
    mpln_misc_run:cancel_timer(Timer_gc),

    Ts = timestamp(),
    ets:select_delete(Cache,[{{'_','_','$1'},[{'<','$1',Ts}],[true]}]),

    Timer_gc_new = erlang:send_after(Config#auth_cnf.cache_gc_interval * 1000, self(), run_gc),
    St#auth_st{timer_gc = Timer_gc_new}.

http_auth_cache(Url, Cookie, Host, #auth_cnf{use_cache=true, cache_lt=Cache_lt} = Config) ->
    Ts_current = timestamp(),
    Cache_key = {Host, Url, Cookie},
    case gen_server:call(?MODULE, {cache_get, Cache_key}) of
        [{Cache_key, Res, Ts}] when ( Ts_current - Ts ) < Cache_lt ->
            erpher_et:trace_me(50, ?MODULE, ?MODULE, 'auth cache used', {?MODULE, ?LINE}),
            ok;
        Cache_res ->
            case Res = http_auth_req(Url, Cookie, Host, Config) of
                {ok,{{_,200,_} = Http_res, _Headers, Data}} ->
                    erpher_et:trace_me(50, ?MODULE, ?MODULE, 'auth cache seted', {?MODULE, ?LINE, Cache_res}),
                    gen_server:cast(?MODULE, {cache_set, {Cache_key, {ok,{Http_res, {}, Data}}}});
                _ ->
                    ok
            end
    end,
    Res;

http_auth_cache(Url, Cookie, Host, Config) ->
    http_auth_req(Url, Cookie, Host, Config).


http_auth_req(Url, Cookie, Host, #auth_cnf{http_connect_timeout=Conn_t, http_timeout=Http_t}) ->
    Hdr = make_header(Cookie, Host),
    Req = make_req(mpln_misc_web:make_string(Url), Hdr),
    erpher_et:trace_me(50, ?MODULE, auth, 'http auth request', {?MODULE, ?LINE, Cookie, Host}),
    Res = httpc:request(post, Req,
        [{timeout, Http_t}, {connect_timeout, Conn_t}],
        [{body_format, binary}]),
    erpher_et:trace_me(50, auth, ?MODULE, 'http auth response', {?MODULE, ?LINE, Res}),
    Res.

%%-----------------------------------------------------------------------------
make_header(Cookie, undefined) ->
    make_header2(Cookie, []);

make_header(Cookie, Host) ->
    Hstr = mpln_misc_web:make_string(Host),
    make_header2(Cookie, [{"Host", Hstr}]).

make_header2(Cookie, List) ->
    Str = mpln_misc_web:make_string(Cookie),
    [{"cookie", Str}, {"User-Agent","erpher"} | List].

%%-----------------------------------------------------------------------------
make_req(Url, Hdr) ->
    {Url, Hdr, "application/x-www-form-urlencoded", <<>>}.