%%%
%%% ecomet_server: server to create children to serve new websocket requests
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
%%% @since 2011-10-14 15:40
%%% @license MIT
%%% @doc server to create children to serve new websocket requests. It connects
%%% to rabbit and creates children with connection provided.
%%%

-module(ecomet_server).
-behaviour(gen_server).

%%%----------------------------------------------------------------------------
%%% Exports
%%%----------------------------------------------------------------------------

-export([start/0, start_link/0, stop/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).
-export([terminate/2, code_change/3]).
-export([add_ws/1, add_ws/2, add_lp/3, add_lp/4]).
-export([add_rabbit_inc_own_stat/0, add_rabbit_inc_other_stat/0]).
-export([lp_get/3, lp_post/4, lp_pid/1]).
-export([subscribe/4]).
-export([del_child/3]).
-export([add_sio/4, del_sio/1, sio_msg/3]).

%%%----------------------------------------------------------------------------
%%% Includes
%%%----------------------------------------------------------------------------

-include("ecomet.hrl").
-include("ecomet_nums.hrl").
-include("ecomet_server.hrl").
-include("ecomet_stat.hrl").
-include("rabbit_session.hrl").

%%%----------------------------------------------------------------------------
%%% gen_server callbacks
%%%----------------------------------------------------------------------------

init(_) ->
    C = ecomet_conf:get_config(),
    New = prepare_all(C),
    [application:start(X) || X <- [sasl, crypto, public_key, ssl]], % FIXME
    mpln_p_debug:pr({'init done', ?MODULE, ?LINE}, New#csr.debug, run, 1),
    {ok, New, ?T}.

%%-----------------------------------------------------------------------------
handle_call({subscribe, Type, Event, No_local, Id}, From, St) ->
    mpln_p_debug:pr({?MODULE, 'subscribe', ?LINE, Id}, St#csr.debug, run, 2),
    St_s = process_subscribe(St, From, Type, Event, No_local, Id),
    New = do_smth(St_s),
    {noreply, New, ?T};
handle_call({post_lp_data, Event, No_local, Id, Data}, From, St) ->
    mpln_p_debug:pr({?MODULE, 'post_lp_data', ?LINE, Id}, St#csr.debug, run, 2),
    St_p = process_lp_post(St, From, Event, No_local, Id, Data),
    New = do_smth(St_p),
    {noreply, New, ?T};
handle_call({get_lp_data, Event, No_local, Id}, From, St) ->
    mpln_p_debug:pr({?MODULE, 'get_lp_data', ?LINE, Id}, St#csr.debug, run, 2),
    St_p = process_lp_req(St, From, Event, No_local, Id),
    New = do_smth(St_p),
    {noreply, New, ?T};
handle_call({add_lp, Sock, Event, No_local, Id}, _From, St) ->
    mpln_p_debug:pr({?MODULE, 'add_lp_child', ?LINE, Id}, St#csr.debug, run, 2),
    {Res, St_c} = check_lp_child(St, Sock, Event, No_local, Id),
    New = do_smth(St_c),
    {reply, Res, New, ?T};
handle_call({add_ws, Event, No_local}, _From, St) ->
    mpln_p_debug:pr({?MODULE, 'add_ws_child', ?LINE}, St#csr.debug, run, 2),
    {Res, St_c} = add_ws_child(St, Event, No_local),
    New = do_smth(St_c),
    {reply, Res, New, ?T};
handle_call({add_sio, Mgr, Handler, Client, Sid}, _From, St) ->
    mpln_p_debug:pr({?MODULE, 'add_sio_child', ?LINE}, St#csr.debug, run, 2),
    {Res, St_c} = add_sio_child(St, Mgr, Handler, Client, Sid),
    New = do_smth(St_c),
    {reply, Res, New, ?T};
handle_call(status, _From, St) ->
    New = do_smth(St),
    {reply, St, New, ?T};
handle_call(stop, _From, St) ->
    {stop, normal, ok, St};
handle_call(_N, _From, St) ->
    New = do_smth(St),
    {reply, {error, unknown_request}, New, ?T}.

%%-----------------------------------------------------------------------------
handle_cast(stop, St) ->
    {stop, normal, St};
handle_cast(add_rabbit_inc_other_stat, St) ->
    St_s = add_msg_stat(St, inc_other),
    New = do_smth(St_s),
    {noreply, New, ?T};
handle_cast(add_rabbit_inc_own_stat, St) ->
    St_s = add_msg_stat(St, inc_own),
    New = do_smth(St_s),
    {noreply, New, ?T};
handle_cast({del_child, Pid, Type, Ref}, St) ->
    St_p = del_child_pid(St, Pid, Type, Ref),
    New = do_smth(St_p),
    {noreply, New, ?T};
handle_cast({lp_pid, Pid}, St) ->
    St_p = add_lp_pid(St, Pid),
    New = do_smth(St_p),
    {noreply, New, ?T};
handle_cast({sio_msg, Pid, Sid, Data}, St) ->
    St_p = process_sio_msg(St, Pid, Sid, Data),
    New = do_smth(St_p),
    {noreply, New, ?T};
handle_cast({del_sio, Pid}, St) ->
    St_p = del_sio_pid(St, Pid),
    New = do_smth(St_p),
    {noreply, New, ?T};
handle_cast(_, St) ->
    New = do_smth(St),
    {noreply, New, ?T}.

%%-----------------------------------------------------------------------------
terminate(_, _State) ->
    yaws:stop(),
    ok.

%%-----------------------------------------------------------------------------
handle_info(timeout, State) ->
    New = do_smth(State),
    {noreply, New, ?T};
handle_info(_, State) ->
    {noreply, State, ?T}.

%%-----------------------------------------------------------------------------
code_change(_Old_vsn, State, _Extra) ->
    {ok, State}.

%%%----------------------------------------------------------------------------
%%% API
%%%----------------------------------------------------------------------------

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
%% @doc creates a process that talks to socket-io child started somewhere else.
%% 'no local' mode (amqp messages from the child should not return to this
%% child).
%% @since 2011-11-22 16:24
%%
-spec add_sio(pid(), atom(), pid(), any()) -> ok.

add_sio(Manager, Handler, Client, Sid) ->
    gen_server:call(?MODULE, {add_sio, Manager, Handler, Client, Sid}).

%%-----------------------------------------------------------------------------
%%
%% @doc sends data from socket-io child to connection handler
%% @since 2011-11-23 14:45
%%
-spec sio_msg(pid(), any(), any()) -> ok.

sio_msg(Client, Sid, Data) ->
    gen_server:cast(?MODULE, {sio_msg, Client, Sid, Data}).

%%-----------------------------------------------------------------------------
%%
%% @doc deletes a process that talks to socket-io child
%% @since 2011-11-23 13:33
%%
-spec del_sio(pid()) -> ok.

del_sio(Client) ->
    gen_server:cast(?MODULE, {del_sio, Client}).

%%-----------------------------------------------------------------------------
%%
%% @doc creates a websocket child with 'no local' mode (amqp messages from
%% the child should not return to this child).
%% @since 2011-10-26 14:14
%%
-spec add_ws(binary()) -> ok.

add_ws(Event) ->
    add_ws(Event, true).

%%-----------------------------------------------------------------------------
%%
%% @doc creates a websocket child with respect to 'no local' mode
%% @since 2011-10-26 14:14
%%
-spec add_ws(binary(), boolean()) -> ok.

add_ws(Event, true) ->
    gen_server:call(?MODULE, {add_ws, Event, true});
add_ws(Event, _) ->
    gen_server:call(?MODULE, {add_ws, Event, false}).

%%-----------------------------------------------------------------------------
%%
%% @doc creates a long-polling child with 'no local' mode
%% (amqp messages from the child should not return to this child).
%% @since 2011-10-26 14:14
%%
-spec add_lp(any(), binary(), non_neg_integer()) -> ok.

add_lp(Sock, Event, Id) ->
    add_lp(Sock, Event, true, Id).

%%-----------------------------------------------------------------------------
%%
%% @doc creates a long-polling child with respect to 'no local' mode
%% @since 2011-10-26 14:14
%%
-spec add_lp(any(), binary(), boolean(), non_neg_integer()) -> ok.

add_lp(Sock, Event, true, Id) ->
    gen_server:call(?MODULE, {add_lp, Sock, Event, true, Id});
add_lp(Sock, Event, _, Id) ->
    gen_server:call(?MODULE, {add_lp, Sock, Event, false, Id}).

%%-----------------------------------------------------------------------------
%%
%% @doc deletes a child from an appropriate list of children
%% @since 2011-11-18 18:00
%%
-spec del_child(pid(), 'ws'|'lp'|'sio', reference()) -> ok.

del_child(Pid, Type, Ref) ->
    gen_server:cast(?MODULE, {del_child, Pid, Type, Ref}).

%%-----------------------------------------------------------------------------
%%
%% @doc gets data for long poll client, creating a handler process if
%% necessary that will handle a session for the given id.
%% @since 2011-11-03 12:26
%%
-spec lp_get(any(), boolean(), non_neg_integer()) -> {ok, binary()}
                                                              | {error, any()}.

lp_get(Event, true, Id) ->
    gen_server:call(?MODULE, {get_lp_data, Event, true, Id}, infinity);
lp_get(Event, _, Id) ->
    gen_server:call(?MODULE, {get_lp_data, Event, false, Id}, infinity).

%%-----------------------------------------------------------------------------
%%
%% @doc gets data for long poll client, creating a handler process if
%% necessary that will handle a session for the given id.
%% @since 2011-11-03 12:26
%%
-spec lp_post(any(), boolean(), non_neg_integer(), binary()) -> {ok, binary()}
                                                              | {error, any()}.

lp_post(Event, true, Id, Data) ->
    gen_server:call(?MODULE, {post_lp_data, Event, true, Id, Data}, infinity);
lp_post(Event, _, Id, Data) ->
    gen_server:call(?MODULE, {post_lp_data, Event, false, Id, Data}, infinity).

%%-----------------------------------------------------------------------------
lp_pid(Pid) ->
    gen_server:cast(?MODULE, {lp_pid, Pid}).

%%-----------------------------------------------------------------------------
%%
%% @doc subscribes the client with given id to the given topic in amqp
%% @since 2011-11-08 18:26
%%
-spec subscribe('ws' | 'lp', binary() | string(), boolean(),
                non_neg_integer()) ->
                       {ok, binary()} | {error, any()}.

subscribe(Type, Event, No_local, Id) ->
    gen_server:call(?MODULE, {subscribe, Type, Event, No_local, Id}, infinity).

%%-----------------------------------------------------------------------------
%%
%% @doc updates statistic messages
%% @since 2011-10-28 16:21
%%
-spec add_rabbit_inc_own_stat() -> ok.

add_rabbit_inc_own_stat() ->
    gen_server:cast(?MODULE, add_rabbit_inc_own_stat).

%%-----------------------------------------------------------------------------
%%
%% @doc updates statistic messages
%% @since 2011-10-28 16:21
%%
-spec add_rabbit_inc_other_stat() -> ok.

add_rabbit_inc_other_stat() ->
    gen_server:cast(?MODULE, add_rabbit_inc_other_stat).

%%%----------------------------------------------------------------------------
%%% Internal functions
%%%----------------------------------------------------------------------------
%%
%% @doc calls supervisor to create child
%%
-spec do_start_child(reference(), list()) ->
                            {ok, pid()} | {ok, pid(), any()} | {error, any()}.

do_start_child(Id, Pars) ->
    Ch_conf = [Pars],
    StartFunc = {ecomet_conn_server, start_link, [Ch_conf]},
    Child = {Id, StartFunc, temporary, 1000, worker, [ecomet_conn_server]},
    supervisor:start_child(ecomet_conn_sup, Child).

%%-----------------------------------------------------------------------------
add_lp_child(St, Sock, Event, No_local, Id) ->
    Pars = [
            {id_web, Id},
            {lp_sock, Sock},
            {event, Event},
            {no_local, No_local},
            {type, 'lp'}
           ],
    add_child(St, Pars).

%%-----------------------------------------------------------------------------
add_ws_child(St, Event, No_local) ->
    Pars = [
            {event, Event},
            {no_local, No_local},
            {type, 'ws'}
           ],
    add_child(St, Pars).

%%-----------------------------------------------------------------------------
add_sio_child(St, Mgr, Handler, Client, Sid) ->
    Pars = [
            {sio_mgr, Mgr},
            {sio_hdl, Handler},
            {sio_cli, Client},
            {sio_sid, Sid},
            {no_local, true}, % FIXME: make it a var?
            {type, 'sio'}
           ],
    add_child(St, Pars).

%%-----------------------------------------------------------------------------
%%
%% @doc creates child, stores its pid in state, checks for error
%% @todo decide about policy on error
%%
-spec add_child(#csr{}, list()) ->
                       {{ok, pid()}, #csr{}}
                           | {{ok, pid(), any()}, #csr{}}
                           | {{error, any()}, #csr{}}.

add_child(St, Ext_pars) ->
    Id = make_ref(),
    Pars = Ext_pars ++ [{id, Id},
                        {conn, St#csr.conn},
                        {exchange_base, (St#csr.rses)#rses.exchange_base}
                        | St#csr.child_config],
    mpln_p_debug:pr({?MODULE, "start child prepared", ?LINE, Id, Pars},
                    St#csr.debug, child, 4),
    Res = do_start_child(Id, Pars),
    mpln_p_debug:pr({?MODULE, "start child result", ?LINE, Id, Pars, Res},
                    St#csr.debug, child, 4),
    Type = proplists:get_value(type, Ext_pars),
    case Res of
        {ok, Pid} ->
            New_st = add_child_list(St, Type, Pid, Id, Ext_pars),
            {Res, New_st};
        {ok, Pid, _Info} ->
            New_st = add_child_list(St, Type, Pid, Id, Ext_pars),
            {Res, New_st};
        {error, Reason} ->
            mpln_p_debug:pr({?MODULE, "start child error", ?LINE, Reason},
                            St#csr.debug, child, 1),
            check_error(St, Reason)
    end.

%%-----------------------------------------------------------------------------
%%
%% @doc gets config for yaws and starts embedded yaws server
%%
start_yaws(C) ->
    Y = C#csr.yaws_config,
    Docroot = proplists:get_value(docroot, Y, ""),
    SconfList = proplists:get_value(sconf, Y, []),
    GconfList = proplists:get_value(gconf, Y, []),
    Id = proplists:get_value(id, Y, "test_yaws_stub"),
    mpln_p_debug:pr({?MODULE, start_yaws, ?LINE, Y,
                     Docroot, SconfList, GconfList, Id}, C#csr.debug, run, 4),
    Res = yaws:start_embedded(Docroot, SconfList, GconfList, Id),
    mpln_p_debug:pr({?MODULE, start_yaws, ?LINE, Res}, C#csr.debug, run, 3).

%%-----------------------------------------------------------------------------
%%
%% @doc prepare log if it is defined in config
%% @since 2011-10-14 14:14
%%
-spec prepare_log(#csr{}) -> ok.

prepare_log(#csr{log=undefined}) ->
    ok;
prepare_log(#csr{log=Log}) ->
    mpln_misc_log:prepare_log(Log).

%%-----------------------------------------------------------------------------
%%
%% @doc prepares all the necessary things (log, rabbit, yaws, etc)
%%
-spec prepare_all(#csr{}) -> #csr{}.

prepare_all(C) ->
    prepare_log(C),
    Cst = prepare_stat(C),
    New = prepare_rabbit(Cst),
    start_yaws(C),
    New.

%%-----------------------------------------------------------------------------
%%
%% @doc prepares rabbit connection
%%
-spec prepare_rabbit(#csr{}) -> #csr{}.

prepare_rabbit(C) ->
    Conn = ecomet_rb:start(C#csr.rses),
    C#csr{conn=Conn}.

%%-----------------------------------------------------------------------------
%%
%% @doc initializes statistic
%%
prepare_stat(C) ->
    St = #stat{rabbit=
                   {
                 ecomet_stat:init(),
                 ecomet_stat:init(),
                 ecomet_stat:init()
                },
               wsock={
                 ecomet_stat:init(),
                 ecomet_stat:init(),
                 ecomet_stat:init()
                }
              },
    C#csr{stat=St}.

%%-----------------------------------------------------------------------------
%%
%% @doc tries to reconnect to rabbit in case of do_start_child returns noproc,
%% which means the connection to rabbit is closed.
%% @todo decide which policy is better - connection restart or terminate itself
%%
check_error(St, {{noproc, _Reason}, _Other}) ->
    mpln_p_debug:pr({?MODULE, "check_error", ?LINE}, St#csr.debug, run, 3),
    New = reconnect(St),
    mpln_p_debug:pr({?MODULE, "check_error new st", ?LINE, New}, St#csr.debug, run, 6),
    {{error, noproc}, New};
check_error(St, Other) ->
    mpln_p_debug:pr({?MODULE, "check_error other", ?LINE}, St#csr.debug, run, 3),
    {{error, Other}, St}.

%%-----------------------------------------------------------------------------
%%
%% @doc does reconnect to rabbit
%%
reconnect(St) ->
    ecomet_rb:teardown_conn(St#csr.conn),
    prepare_rabbit(St).

%%-----------------------------------------------------------------------------
%%
%% @doc checks whether the child with given type and id is alive
%%
ensure_child(#csr{ws_children=Ch} = St, 'ws', Id) ->
    case is_child_alive(St, Ch, Id) of
        {true, I} ->
            {{ok, I#chi.pid}, St};
        {false, _} ->
            {error, no_websocket_child}
    end;
ensure_child(St, 'lp', Id) ->
    check_lp_child(St, undefined, undefined, undefined, Id);
ensure_child(St, 'sio', Pid) ->
    check_sio_child(St, Pid).

%%-----------------------------------------------------------------------------
%%
%% @doc checks whether the child with given id is alive. If yes, then
%% charges it to do some work, otherwise creates the one
%%
-spec check_lp_child(#csr{},
                     undefined | any(),
                     undefined | binary(),
                     undefined | boolean(),
                     non_neg_integer()) ->
                            {{ok, pid()}, #csr{}}
                                | {{ok, pid(), any()}, #csr{}}
                                | {{error, any()}, #csr{}}.

check_lp_child(#csr{lp_children = Ch} = St, Sock, Event, No_local, Id) ->
    case is_child_alive(St, Ch, Id) of
        {true, I} ->
            charge_child(St, I#chi.pid);
        {false, _} ->
            add_lp_child(St, Sock, Event, No_local, Id)
    end.

%%-----------------------------------------------------------------------------
%%
%% @doc finds child with given id and checks whether it's alive
%%
is_child_alive(St, List, Id) ->
    mpln_p_debug:pr({?MODULE, "is_child_alive", ?LINE, List, Id},
                    St#csr.debug, run, 4),
    L2 = [X || X <- List, X#chi.id_web == Id],
    mpln_p_debug:pr({?MODULE, "is_child_alive", ?LINE, L2, Id},
                    St#csr.debug, run, 4),
    case L2 of
        [I | _] ->
            {is_process_alive(I#chi.pid), I};
        _ ->
            {false, undefined}
    end.

%%-----------------------------------------------------------------------------
%%
%% @doc child just waits for incoming messages from amqp. All we need
%% here is to return its pid.
%%
-spec charge_child(#csr{}, pid()) -> {{ok, pid()}, #csr{}}.

charge_child(St, Pid) ->
    mpln_p_debug:pr({?MODULE, "charge child", ?LINE, Pid},
                    St#csr.debug, child, 4),
    {{ok, Pid}, St}.

%%-----------------------------------------------------------------------------
%%
%% @doc adds child info into appropriate list - either web socket or long poll
%% in dependence of given child type.
%%
-spec add_child_list(#csr{}, 'ws' | 'lp' | 'sio', pid(), reference(),
                     list()) -> #csr{}.

add_child_list(St, Type, Pid, Id, Pars) ->
    Id_web = proplists:get_value(id_web, Pars),
    Data = #chi{pid=Pid, id=Id, id_web=Id_web, start=now()},
    add_child_list2(St, Type, Data, Pars).

add_child_list2(#csr{ws_children=C} = St, 'ws', Data, _) ->
    St#csr{ws_children=[Data | C]};
add_child_list2(#csr{lp_children=C} = St, 'lp', Data, _) ->
    St#csr{lp_children=[Data | C]};
add_child_list2(#csr{sio_children=C} = St, 'sio', Data, Pars) ->
    Ev_mgr = proplists:get_value(sio_mgr, Pars),
    Client = proplists:get_value(sio_cli, Pars),
    Sid = proplists:get_value(sio_sid, Pars),
    New = Data#chi{sio_mgr=Ev_mgr, sio_cli=Client, sio_sid=Sid},
    St#csr{sio_children=[New | C]}.

%%-----------------------------------------------------------------------------
%%
%% @doc creates a handler process if it's not done yet, charges the process
%% to do the work
%%
-spec process_lp_req(#csr{}, any(), any(), boolean(), non_neg_integer()) ->
                      #csr{}.

process_lp_req(St, From, Event, No_local, Id) ->
    case check_lp_child(St, undefined, Event, No_local, Id) of
        {{ok, Pid}, St_c} ->
            ecomet_conn_server:get_lp_data(Pid, From),
            St_c;
        {{ok, Pid, _Info}, St_c} ->
            ecomet_conn_server:get_lp_data(Pid, From),
            St_c;
        {{error, _Reason} = Res, _New_st} ->
            gen_server:reply(From, Res),
            St
    end.

%%-----------------------------------------------------------------------------
%%
%% @doc creates a handler process if it's not done yet, charges the process
%% to handle the post request
%%
-spec process_lp_post(#csr{}, any(), any(), boolean(),  non_neg_integer(),
                      binary()) -> #csr{}.

process_lp_post(St, From, Event, No_local, Id, Data) ->
    case check_lp_child(St, undefined, Event, No_local, Id) of
        {{ok, Pid}, St_c} ->
            ecomet_conn_server:post_lp_data(Pid, From, Data),
            St_c;
        {{ok, Pid, _Info}, St_c} ->
            ecomet_conn_server:post_lp_data(Pid, From, Data),
            St_c;
        {{error, _Reason} = Res, _New_st} ->
            gen_server:reply(From, Res),
            St
    end.

%%-----------------------------------------------------------------------------
add_msg_stat(#csr{stat=#stat{rabbit=Rb_stat} = Stat} = State, Tag) ->
    New_rb_stat = ecomet_stat:add_server_stat(Rb_stat, Tag),
    New_stat = Stat#stat{rabbit=New_rb_stat},
    State#csr{stat = New_stat}.

%%-----------------------------------------------------------------------------
-spec process_subscribe(#csr{}, any(), 'ws'|'lp', binary(), boolean(),
                        non_neg_integer()) -> #csr{}.

process_subscribe(St, From, Type, Event, No_local, Id) ->
    mpln_p_debug:pr({?MODULE, "process_subscribe", ?LINE,
                     From, Type, Event, No_local, Id},
                    St#csr.debug, child, 4),
    case ensure_child(St, Type, Id) of
        {{ok, Pid}, St_c} ->
            mpln_p_debug:pr({?MODULE, "process_subscribe ok 1", ?LINE, Id},
                            St#csr.debug, child, 4),
            ecomet_conn_server:subscribe(Pid, From, Event, No_local),
            St_c;
        {{ok, Pid, _Info}, St_c} ->
            mpln_p_debug:pr({?MODULE, "process_subscribe ok 2", ?LINE, Id},
                            St#csr.debug, child, 4),
            ecomet_conn_server:subscribe(Pid, From, Event, No_local),
            St_c;
        {error, _Reason} = Res ->
            mpln_p_debug:pr({?MODULE, "process_subscribe err 1", ?LINE, Id, Res},
                            St#csr.debug, child, 2),
            gen_server:reply(From, Res),
            St
    end.

%%-----------------------------------------------------------------------------
%%
%% @doc adds yaws process that serves long poll piece of s^H data to the
%% list for later terminating
%%
add_lp_pid(#csr{lp_yaws=L} = St, Pid) ->
    Y = #yp{pid = Pid, start = now()},
    St#csr{lp_yaws = [Y | L]}.

%%-----------------------------------------------------------------------------
%%
%% @doc deletes a terminated long poll process from a list of children
%%
del_lp_pid(#csr{lp_children=L} = St, Pid, Ref) ->
    L2 = [X || X <- L, (X#chi.pid =/= Pid) or (X#chi.id =/= Ref)],
    St#csr{lp_children = L2}.

%%-----------------------------------------------------------------------------
%%
%% @doc deletes and terminates socket-io related process from a list of children
%%
del_sio_pid(#csr{sio_children=L} = St, Pid) ->
    mpln_p_debug:pr({?MODULE, del_sio_pid, ?LINE, Pid},
                    St#csr.debug, run, 4),
    F = fun(#chi{sio_cli=C_pid}) ->
                C_pid == Pid
        end,
    {Del, Cont} = lists:partition(F, L),
    mpln_p_debug:pr({?MODULE, del_sio_pid, ?LINE, Del, Cont},
                    St#csr.debug, run, 5),
    terminate_sio_children(St, Del),
    St#csr{sio_children = Cont}.

%%-----------------------------------------------------------------------------
%%
%% @doc terminates socket-io related process
%%
terminate_sio_children(St, List) ->
    F = fun(#chi{pid=Pid}) ->
                Info = process_info(Pid),
                mpln_p_debug:pr({?MODULE, terminate_sio_children, ?LINE, Info},
                                St#csr.debug, run, 5),
                ecomet_conn_server:stop(Pid)
        end,
    lists:foreach(F, List).

%%-----------------------------------------------------------------------------
%%
%% @doc does periodic tasks: clean yaws long poll process, etc
%%
do_smth(St) ->
    St_e = check_ecomet_long_poll(St),
    St_lp = check_yaws_long_poll(St_e),
    St_lp.

%%-----------------------------------------------------------------------------
%%
%% @doc checks if there was enough time since last cleaning and calls
%% clean_yaws_long_poll. This time check is performed to call cleaning
%% not too frequently
%%
-spec check_yaws_long_poll(#csr{}) -> #csr{}.

check_yaws_long_poll(#csr{lp_yaws_last_check=undefined} = St) ->
    St#csr{lp_yaws_last_check=now()};
check_yaws_long_poll(#csr{lp_yaws_last_check=Last, lp_yaws_check_interval=T}
                     = St) ->
    Now = now(),
    Delta = timer:now_diff(Now, Last),
    if Delta > T * 1000 ->
            clean_yaws_long_poll(St#csr{lp_yaws_last_check=Now});
       true ->
            St
    end.

%%-----------------------------------------------------------------------------
%%
%% @doc iterates over the list of yaws long poll processes and terminates
%% those that last too long
%% @todo rewrite it to use legal Yaws API and not "fast and dirty hacks"
%% @todo do it on timer (say once a second) and not always
%%
-spec clean_yaws_long_poll(#csr{}) -> #csr{}.

clean_yaws_long_poll(#csr{lp_yaws_request_timeout=Timeout, lp_yaws=L} = St) ->
    Now = now(),
    F = fun(#yp{pid=Pid, start=T} = Ypid, Acc) ->
                Delta = timer:now_diff(Now, T),
                if Delta > Timeout * 1000000 ->
                        exit(Pid, kill),
                        Acc;
                   true ->
                        [Ypid | Acc]
                end
        end,
    New_list = lists:foldl(F, [], L),
    St#csr{lp_yaws=New_list}.

%%-----------------------------------------------------------------------------
%%
%% @doc checks if there was enough time since last cleaning and calls
%% clean_ecomet_long_poll. This time check is performed to call cleaning
%% not too frequently
%%
-spec check_ecomet_long_poll(#csr{}) -> #csr{}.

check_ecomet_long_poll(#csr{lp_last_check=undefined} = St) ->
    St#csr{lp_last_check=now()};
check_ecomet_long_poll(#csr{lp_last_check=Last, lp_check_interval=T} = St) ->
    Now = now(),
    Delta = timer:now_diff(Now, Last),
    if Delta > T * 1000 ->
            clean_ecomet_long_poll(St#csr{lp_last_check=Now});
       true ->
            St
    end.

%%-----------------------------------------------------------------------------
%%
%% @doc cleans away old long poll processes from the list. Just cleans
%% the list, no any killing spree is involved here because processes terminate
%% themselves
%%
clean_ecomet_long_poll(#csr{lp_request_timeout=Timeout, lp_children=L} = St) ->
    Now = now(),
    F = fun(#chi{start=T}) ->
                Delta = timer:now_diff(Now, T),
                Delta =< Timeout * 1000000
        end,
    New_list = lists:filter(F, L),
    St#csr{lp_children=New_list}.

%%-----------------------------------------------------------------------------
%%
%% @doc creates a handler process if it's not done yet, charges the process
%% to do the work
%%
process_sio_msg(St, _Client, Sid, Data) ->
    case check_sio_child(St, Sid) of
        {{ok, Pid}, St_c} ->
            ecomet_conn_server:data_from_sio(Pid, Data),
            St_c;
        {{ok, Pid, _}, St_c} ->
            ecomet_conn_server:data_from_sio(Pid, Data),
            St_c;
        {{error, _Reason}, _St_c} ->
            St
    end.

%%-----------------------------------------------------------------------------
%%
%% @doc checks whether the socket-io child with given id is alive. Creates
%% the one if it's not.
%%
-spec check_sio_child(#csr{}, any()) ->
                            {{ok, pid()}, #csr{}}
                                | {{ok, pid(), any()}, #csr{}}
                                | {{error, any()}, #csr{}}.

check_sio_child(#csr{sio_children = Ch} = St, Sid) ->
    case is_sio_child_alive(St, Ch, Sid) of
        {true, I} ->
            {{ok, I#chi.pid}, St};
        {false, _} ->
            add_sio_child(St, undefined, undefined, undefined, Sid)
    end.

%%-----------------------------------------------------------------------------
%%
%% @doc finds socket-io child with given client id and checks whether it's
%% alive
%%
is_sio_child_alive(St, List, Id) ->
    mpln_p_debug:pr({?MODULE, "is_sio_child_alive", ?LINE, List, Id},
                    St#csr.debug, run, 4),
    L2 = [X || X <- List, X#chi.sio_sid == Id],
    mpln_p_debug:pr({?MODULE, "is_sio_child_alive", ?LINE, L2, Id},
                    St#csr.debug, run, 4),
    case L2 of
        [I | _] ->
            {is_process_alive(I#chi.pid), I};
        _ ->
            {false, undefined}
    end.

%%-----------------------------------------------------------------------------
%%
%% @doc deletes a child from a list of children
%%
del_child_pid(St, Pid, 'lp', Ref) ->
    del_lp_pid(St, Pid, Ref);
del_child_pid(St, Pid, 'sio', _Ref) ->
    del_sio_pid(St, Pid).

%%-----------------------------------------------------------------------------
