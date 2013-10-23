%%%
%%% ecomet_conn_server_sjs: miscellaneous functions for ecomet connection server
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
%%% @since 2012-01-19 12:04
%%% @license MIT
%%% @doc miscellaneous functions for ecomet connection server
%%%

-module(ecomet_conn_server_sjs).

%%%----------------------------------------------------------------------------
%%% Exports
%%%----------------------------------------------------------------------------

-export([process_msg/2]).
-export([send/3, send_debug/2, send_simple/2, send_error/2]).
-export([recheck_auth/1]).
-export([process_msg_from_server/2]).

%%%----------------------------------------------------------------------------
%%% Includes
%%%----------------------------------------------------------------------------

%-include_lib("socketio.hrl").
-include("ecomet_child.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

%%%----------------------------------------------------------------------------
%%% API
%%%----------------------------------------------------------------------------
%%
%% @doc does recheck auth. If url/cookie are undefined then it means
%% the process has not received any auth info from a web client yet.
%%
-spec recheck_auth(#child{}) -> #child{}.

recheck_auth(#child{auth = #auth_data{url=undefined, cookie=undefined}, id_s=undefined} = St) ->
    St;

recheck_auth(#child{auth = Auth_data} = St) ->
    erpher_et:trace_me(50, ?MODULE, ecomet_auth_server, 'auth request', {?MODULE, ?LINE}),
    Res_auth = ecomet_auth_server:proceed_http_auth_req(Auth_data),
    erpher_et:trace_me(50, ecomet_auth_server, ?MODULE, 'auth response', {?MODULE, ?LINE}),

    erpher_et:trace_me(50, ?MODULE, ?MODULE, proceed_auth_msg, {?MODULE, ?LINE}),
    proceed_auth_msg(St#child{auth_last=now()}, Res_auth, [{<<"type">>, 'reauth'}]).

%%-----------------------------------------------------------------------------
%%
%% @doc forward data received from ecomet_server to sockjs connection
%% @since 2012-01-23 16:10
%%
-spec process_msg_from_server(#child{}, any()) -> #child{}.

process_msg_from_server(#child{sjs_conn=Conn} = St, Data) ->
    erpher_et:trace_me(50, ?MODULE, sockjs, send, {?MODULE, ?LINE}),
    sockjs:send(Data, Conn),
    St.

%%-----------------------------------------------------------------------------
%%
%% @doc processes data received from socket-io, stores auth data if presents
%% for later checks
%% @since 2011-11-24 12:40
%%
-spec process_msg(#child{}, binary()) -> #child{}.

process_msg(#child{id=Id, id_s=Uid} = St, Bin) ->
    Data = get_json_body(Bin),
    erpher_et:trace_me(50, ?MODULE, ecomet_data_msg, get_auth_info, {?MODULE, ?LINE, Bin}),
    case ecomet_data_msg:get_auth_info(Data) of
        undefined when Uid == undefined ->
            mpln_p_debug:pr({?MODULE, 'process_msg', ?LINE, 'no auth data', Id}, St#child.debug, run, 4),
            St;
        undefined ->
            Type = ecomet_data_msg:get_type(Data),
            proceed_type_msg(St, use_current_exchange, Type, Data, [{<<"error">>, <<"auth required">>},{<<"data">>, Data}]);
        Auth ->
            {Res_auth, Auth_data} = send_auth_req(St, Auth),
            erpher_et:trace_me(50, ?MODULE, ?MODULE, proceed_auth_msg, {?MODULE, ?LINE}),
            proceed_auth_msg(St#child{auth = Auth_data}, Res_auth, Data)
    end.

%%-----------------------------------------------------------------------------
%%
%% @doc sends content and routing key to sockjs client
%% @since 2011-11-24 12:40
%%
-spec send(#child{}, binary(), binary() | string()) -> #child{}.

send(#child{id=Id, id_s=undefined} = St, _Key, _Body) ->
    send_debug(St, <<"undefined uid">>),
    mpln_p_debug:er({?MODULE, ?LINE, Id, 'send to undefined uid'}),
    St;

send(#child{id_s=User, sjs_conn=Conn} = St, Key, Body) ->
    Content = get_json_body(Body),
    Users = ecomet_data_msg:get_users(Content),
    case is_user_allowed(User, Users) of
        true ->
            Message = ecomet_data_msg:get_message(Content),
            Data = [{<<"event">>, Key},
                {<<"user">>, User},
                {<<"message">>, Message}],
            % encoding hack here is necessary, because current socket-io
            % backend (namely, misultin) crashes on encoding cyrillic utf8.
            % Cowboy isn't tested yet for this.
            %Json = sockjs_util:encode({Data}), % for jiffy
            Json = mochijson2:encode(Data), % for mochijson2
            %Json = mochijson2:encode(Data),
            Msg = iolist_to_binary(Json),
            %Json_s = binary_to_list(Json_b),
            %Msg = Json_b, % for sockjs
            erpher_et:trace_me(50, ?MODULE, sockjs, send, {?MODULE, ?LINE, Msg}),
            sockjs:send(Msg, Conn),
            St;
        false ->
            send_debug(St, <<"user is not allowed by msg">>),
            St
    end.


%%-----------------------------------------------------------------------------
%%
%% @doc send message to socket
%%
send_simple(#child{sjs_conn=Conn}, Data) ->
    Json = mochijson2:encode(Data), % for mochijson2
    Msg = iolist_to_binary(Json),
    sockjs:send(Msg, Conn).

%%-----------------------------------------------------------------------------
%%
%% @doc send debug message to socket if enabled
%%
send_debug(#child{sjs_debug=false}, _Data) ->
    ok;

send_debug(#child{sjs_conn=Conn} = St, Data) ->
    send_simple(#child{sjs_conn=Conn} = St, [{<<"debug">>, Data}]).

%%-----------------------------------------------------------------------------
%%
%% @doc send error message to socket
%%
send_error(#child{sjs_conn=Conn} = St, Error) ->
    send_simple(#child{sjs_conn=Conn} = St, [{<<"error">>, Error}]),
    ok.

%%%----------------------------------------------------------------------------
%%% Internal functions
%%%----------------------------------------------------------------------------
%%
%% @doc checks if current user is in user list. Empty or undefined list of
%% users means "allow".
%%
is_user_allowed(_User, []) ->
    true;
is_user_allowed(_User, undefined) ->
    true;
is_user_allowed(User, Users) ->
    lists:member(User, Users).

%%-----------------------------------------------------------------------------
%%
%% @doc makes request to auth server. Returns http answer, auth url, auth cookie
%%
-spec send_auth_req(#child{}, list()) -> {{ok, any()} | {error, any()},
                                          binary(), binary(),
                                          undefined | binary()}.

send_auth_req(#child{cookie_matcher = Cookie_matcher} = St, Info) ->
    Url_base = ecomet_data_msg:get_auth_url(Info),
    {Url, Host} = find_auth_host(St, Url_base),
    Auth = #auth_data{
        url = Url,
        host = Host,
        token = ecomet_data_msg:get_auth_token(Info),
        cookie = ecomet_data_msg:get_auth_cookie(Info, Cookie_matcher)
    },
    erpher_et:trace_me(50, ?MODULE, ecomet_auth_server, 'auth request', {?MODULE, ?LINE, Auth}),
    send_debug(St, <<"auth request start">>),
    Res = ecomet_auth_server:proceed_http_auth_req(Auth),
    send_debug(St, <<"auth request finish">>),
    erpher_et:trace_me(50, ecomet_auth_server, ?MODULE, 'auth response', {?MODULE, ?LINE, Res}),
    {Res, Auth}.

%%-----------------------------------------------------------------------------
%%
%% @doc extracts auth data from url and returns cleaned url and auth host
%% (login field of auth data)
%%
-spec find_auth_host(#child{}, binary()) -> {binary(), undefined | binary()}.

find_auth_host(#child{user_data_as_auth_host=true}, Url) ->
    Ustr = mpln_misc_web:make_string(Url),
    case http_uri:parse(Ustr) of
        {error, _Reason} ->
            {Url, undefined};
        {ok, {_, User_info, _, _, _, _}} when User_info == "" ->
            {Url, undefined};
        {ok, {Scheme, User_info, Host, Port, Path, Query}} ->
            Scheme_str = [atom_to_list(Scheme), "://"],
            Port_str = integer_to_list(Port),
            Str = [Scheme_str, "", Host, ":", Port_str, Path, Query],
            Res_url = unicode:characters_to_binary(Str),
            Auth_host = make_auth_host(User_info),
            {Res_url, Auth_host}
        end;

find_auth_host(_, Url) ->
    {Url, undefined}.
    
%%-----------------------------------------------------------------------------
%%
%% @doc splits input string with ":" and returns first token as a binary
%%
make_auth_host(Str) ->
    case string:tokens(Str, ":") of
        [H|_] ->
            iolist_to_binary(H);
        _ ->
            <<>>
    end.

%%-----------------------------------------------------------------------------
%%
%% @doc checks auth data received from auth server
%%
proceed_auth_msg(St, {ok, Info}, Data) ->
    {Uid, Exch} = process_auth_resp(St, Info),
    Type = ecomet_data_msg:get_type(Data),
    proceed_type_msg(St#child{id_s=Uid}, Exch, Type, Data, Info);

proceed_auth_msg(#child{auth = Auth_data} = St, {error, Reason}, _Data) ->
    send_error(St, <<"auth failed">>),
    mpln_p_debug:er({?MODULE, ?LINE, proceed_auth_msg_error, Auth_data, Reason}),
    ecomet_conn_server:stop(self()),
    St#child{id_s = undefined}.

%%-----------------------------------------------------------------------------
%%
%% @doc prepares queues and bindings
%%
-spec proceed_type_msg(#child{}, use_current_exchange | binary(),
                       reauth | binary(),
                       any(), any()) -> #child{}.

%% @doc bad auth
proceed_type_msg(#child{id_s = <<"undefined">>} = St, Exchange, Type, Data, Info) ->
    proceed_type_msg(St#child{id_s=undefined}, Exchange, Type, Data, Info),
    St;

proceed_type_msg(#child{id=Id, id_s=undefined, auth = Auth_data} = St, _, _, _, Info) ->
    send_error(St, <<"auth bad">>),
    mpln_p_debug:er({?MODULE, ?LINE, proceed_type_msg, <<"userId not found">>, Auth_data, Info, Id}),
    ecomet_conn_server:stop(self()),
    St;

proceed_type_msg(St, Exchange, Type, Data, _Info) ->
    proceed_type_msg(St, Exchange, Type, Data).

%% @doc reauth
proceed_type_msg(#child{conn=Conn, no_local=No_local, routes=Routes} = St, Exchange, 'reauth', _Data) ->
    erpher_et:trace_me(50, ?MODULE, ?MODULE, 'proceed_type_msg reauth', {?MODULE, ?LINE}),
    erpher_et:trace_me(50, ?MODULE, ecomet_rb, prepare_queue_rebind, {?MODULE, ?LINE}),
    New = ecomet_rb:prepare_queue_rebind(Conn, Exchange, Routes, [], No_local),
    send_debug(St, <<"reauth">>),
    St#child{conn = New};

%% @doc subscribe some topics
proceed_type_msg(#child{conn=Conn, no_local=No_local, routes=Old_routes} = St, Exchange, <<"subscribe">>, Data) ->
    erpher_et:trace_me(50, ?MODULE, ?MODULE, 'proceed_type_msg subscribe', {?MODULE, ?LINE}),
    Routes_dirty = ecomet_data_msg:get_routes(Data, []),
    Routes = lists:filter( fun(E) -> IsMember = lists:member(E, Old_routes), if IsMember -> false; true -> true end end, Routes_dirty),
    New = case Exchange of
              use_current_exchange ->
                  erpher_et:trace_me(50, ?MODULE, ecomet_rb, prepare_queue_add_bind, {?MODULE, ?LINE}),
                  ecomet_rb:prepare_queue_add_bind(Conn, Routes, No_local);
              _ ->
                  erpher_et:trace_me(50, ?MODULE, ecomet_rb, prepare_queue_rebind, {?MODULE, ?LINE}),
                  ecomet_rb:prepare_queue_rebind(Conn, Exchange, Old_routes, Routes, No_local)
          end,
    St_new = St#child{conn = New, routes = Routes ++ Old_routes},
    send_debug(St_new, St_new#child.routes),
    St_new;

%% @doc unsubscribe some topics
proceed_type_msg(St, _Exchange, <<"unsubscribe">>, Data) ->
    Routes = ecomet_data_msg:get_routes(Data, []),
    erpher_et:trace_me(50, ?MODULE, ?MODULE, 'proceed_type_msg unsubscribe', {?MODULE, ?LINE, Routes}),
    St_new = unsubscribe(St, Routes),
    send_debug(St_new, St_new#child.routes),
    St_new;

%% @doc debug
proceed_type_msg(St, _Exchange, <<"debug">>, _Data) ->
    erpher_et:trace_me(50, ?MODULE, ?MODULE, 'proceed_type_msg debug on', {?MODULE, ?LINE, _Data}),
    St_new = St#child{sjs_debug = true},
    send_debug(St_new, <<"on">>),
    St_new;

%% @doc debug off
proceed_type_msg(St, _Exchange, <<"debug_off">>, _Data) ->
    erpher_et:trace_me(50, ?MODULE, ?MODULE, 'proceed_type_msg debug off', {?MODULE, ?LINE, _Data}),
    St_new = St#child{sjs_debug = false},
    send_debug(St, <<"off">>),
    St_new;

proceed_type_msg(St, _Exchange, Other, _Data) ->
    mpln_p_debug:er({?MODULE, ?LINE, proceed_type_msg, other, Other}),
    St.

%%-----------------------------------------------------------------------------
%%
%% @doc unsubscribe
%%
-spec unsubscribe(#child{}, [binary()]) -> #child{}.

unsubscribe(#child{conn=Conn, routes=Old_routes} = St, [Route|Routes]) ->
    St_new = case lists:member(Route, Old_routes) of
        true ->
            erpher_et:trace_me(50, ?MODULE, ecomet_rb, queue_unbind, {?MODULE, ?LINE, Route}),
            Conn_new = ecomet_rb:prepare_queue_unbind_one(Conn, Route),
            St#child{conn = Conn_new, routes = lists:delete(Route, Old_routes)};

        false ->
            mpln_p_debug:er({?MODULE, ?LINE, <<"unsubscribe unknown route">>, Route}),
            send_debug(St, <<"unsubscribe unknown route">>),
            St
    end,
    unsubscribe(St_new, Routes);

unsubscribe(St, []) ->
    St.

%%-----------------------------------------------------------------------------
%%
%% @doc decodes json http response, creates exchange response is success,
%% returns user_id and exchange
%%
-spec process_auth_resp(#child{},
                        {
                          {string(), list(), any()} | {integer(), any()},
                          any()
                        }) -> {integer() | undefined, binary()}.

process_auth_resp(St, {{_, 200, _} = _Sline, _Hdr, Body}) ->
    proceed_process_auth_resp(St, Body);

process_auth_resp(St, {200 = _Scode, Body}) ->
    proceed_process_auth_resp(St, Body);

process_auth_resp(_, _) ->
    {undefined, <<>>}.

%%-----------------------------------------------------------------------------
%%
%% @doc decodes json http response, creates exchange. Returns user_id and
%% exchange
%%
proceed_process_auth_resp(#child{id=Id} = St, Body) ->
    case get_json_body(Body) of
        undefined ->
            mpln_p_debug:er({?MODULE, ?LINE, Id, json_error, Body}),
            {undefined, <<>>};
        Data ->
            X = create_exchange(St, Data),
            Uid = ecomet_data_msg:get_user_id(Data),
            % uids MUST come as strings in data, so json decoder would
            % return them as binaries. So we make the current user id
            % a binary for later check for allowed users
            Uid_bin = mpln_misc_web:make_binary(Uid),
            {Uid_bin, X}
    end.

%%-----------------------------------------------------------------------------
%%
%% @doc decodes json data
%%
get_json_body(Body) ->
    case catch mochijson2:decode(Body) of
        {ok, {List}} when is_list(List) ->
            List;
        {ok, Data} ->
            Data;
        {'EXIT', _Reason} ->
            undefined;
        Data ->
            Data
    end.

%%-----------------------------------------------------------------------------
%%
%% @doc creates topic exchange with name tail defined in the input data
%%
create_exchange(#child{conn=Conn, exchange_base=Base} = St, Data) ->
    Acc = ecomet_data_msg:get_account(Data),
    Exchange = <<Base/binary, Acc/binary>>,
    mpln_p_debug:pr({?MODULE, 'create_exchange', ?LINE, Exchange}, St#child.debug, run, 2),
    ecomet_rb:create_exchange(Conn, Exchange, <<"topic">>),
    Exchange.

%%%----------------------------------------------------------------------------
%%% EUnit tests
%%%----------------------------------------------------------------------------
-ifdef(TEST).

get_json() ->
    "{\"userId\":123,\"account\":\"acc_name_test\"}"
    .

get_json_test() ->
    B = get_json(),
    J0 = {struct,[{<<"userId">>,123},{<<"account">>,<<"acc_name_test">>}]},
    J1 = get_json_body(B),
    ?assert(J0 =:= J1).

get_auth_part() ->
    {<<"auth">>,
     [{<<"authUrl">>,<<"http://mdt-symfony/comet/auth">>},
      {<<"cookie">>,
       <<"socketio=websocket; PHPSESSID=qwerasdf45ty67u87i98o90p2d">>}]}.

get_msg() ->
    A = get_auth_part(),
    [{<<"type">>,<<"subscribe">>},
     {<<"routes">>,
      [<<"discuss.topic.comment.14">>,<<"user.live.notify">>]},
     A
    ].

get_auth_test() ->
    A0 = get_auth_part(),
    Data = get_msg(),
    A1b = ecomet_data_msg:get_auth_info(Data),
    A1 = {<<"auth">>, A1b},
    %?debugFmt("get_auth_test:~n~p~n~p~n~p~n", [A0, Data, A1]),
    ?assert(A0 =:= A1).

get_url_test() ->
    U0 = <<"http://mdt-symfony/comet/auth">>,
    Data = get_msg(),
    Info = ecomet_data_msg:get_auth_info(Data),
    U1 = ecomet_data_msg:get_auth_url(Info),
    %?debugFmt("get_url_test:~n~p~n~p~n", [U0, U1]),
    ?assert(U0 =:= U1).

get_cookie_test() ->
    C0 = <<"socketio=websocket; PHPSESSID=qwerasdf45ty67u87i98o90p2d">>,
    Data = get_msg(),
    Info = ecomet_data_msg:get_auth_info(Data),
    C1 = ecomet_data_msg:get_auth_cookie(Info),
    %?debugFmt("get_url_test:~n~p~n~p~n", [C0, C1]),
    ?assert(C0 =:= C1).

find_auth_host_test() ->
    St = #child{user_data_as_auth_host=true,
                debug=[]},
    Lst = [
           {
             <<"http://mdt-symfony/comet/auth">>, true,
             <<"http://mdt-symfony/comet/auth">>, undefined
            },
           {
             <<"http://mdt-symfony/comet/auth">>, false,
             <<"http://mdt-symfony/comet/auth">>, undefined
           },
           {
             <<"http://test.megaplan@mdt-symfony/comet/auth">>, true,
             <<"http://mdt-symfony:80/comet/auth">>, <<"test.megaplan">>
           },
           {
             <<"http://test.megaplan@mdt-symfony/comet/auth">>, false,
             <<"http://test.megaplan@mdt-symfony/comet/auth">>, undefined
           },
           {
             <<"http://test.megaplan#@mdt-symfony/comet/auth">>, true,
             <<"http://mdt-symfony:80/comet/auth">>, <<"test.megaplan#">>
           },
           {
             <<"http://test.megaplan#mdt-symfony/comet/auth">>, true,
             <<"http://test.megaplan#mdt-symfony/comet/auth">>, undefined
           }
          ],
    F = fun({Url, Flag, Url0, Hdr0} = _Item) ->
                Config = St#child{user_data_as_auth_host=Flag},
                Res = find_auth_host(Config, Url),
                %?debugFmt("find_auth_host_test:~n~p~n~p~n", [Item, Res]),
                ?assert({Url0, Hdr0} =:= Res)
        end,
    lists:foreach(F, Lst).

-endif.
%%-----------------------------------------------------------------------------
