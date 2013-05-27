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
%%% @doc server to create children to serve new comet requests. Upon a request
%%% from a underlying comet (sockjs) library. It connects
%%% to rabbit and creates children with amqp connection provided.
%%%

-module(ecomet_server).
-behaviour(gen_server).

%%%----------------------------------------------------------------------------
%%% Exports
%%%----------------------------------------------------------------------------

-export([start/0, start_link/0, stop/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).
-export([terminate/2, code_change/3]).
-export([del_child/3]).
-export([sjs_add/2, sjs_del/2, sjs_msg/3]).
-export([sjs_broadcast_msg/1]).
-export([reload_config_signal/0, get_stat_procs/0, get_stat_procs_mem/0]).

%%%----------------------------------------------------------------------------
%%% Includes
%%%----------------------------------------------------------------------------

-include("ecomet.hrl").
-include("ecomet_nums.hrl").
-include("ecomet_server.hrl").
-include("rabbit_session.hrl").

%%%----------------------------------------------------------------------------
%%% gen_server callbacks
%%%----------------------------------------------------------------------------

init(_) ->
    process_flag(trap_exit, true),
    C = ecomet_conf:get_config(),
    New = prepare_all(C),
    mpln_p_debug:pr({?MODULE, 'init', ?LINE}, New#csr.debug, run, 1),
    {ok, New}.

%%-----------------------------------------------------------------------------
% @doc returns accumulated statistic as a list of tuples
% {atom(), {dict(), dict(), dict()}}
handle_call({get_stat, Tag}, _From, St) ->
    Res = prepare_stat_result(St, Tag),
    {reply, Res, St};

handle_call(status, _From, St) ->
    {reply, St, St};
handle_call(stop, _From, St) ->
    {stop, normal, ok, St};
handle_call(_N, _From, St) ->
    mpln_p_debug:er({?MODULE, ?LINE, unknown_request, _N}),
    {reply, {error, unknown_request}, St}.

handle_call(_N, St) ->
    mpln_p_debug:er({?MODULE, ?LINE, unknown_request, _N}),
    {reply, {error, unknown_request}, St}.

%%-----------------------------------------------------------------------------
handle_cast(stop, St) ->
    {stop, normal, St};

handle_cast({del_child, Pid, Type, Ref}, St) ->
    New = del_child_pid(St, Pid, Type, Ref),
    {noreply, New};

handle_cast({sjs_add, Sid, Conn}, St) ->
    erpher_et:trace_me(50, ?MODULE, ?MODULE, 'cast add start', {?MODULE, ?LINE}),
    %T1 = now(),
    {_Res, St_new} = add_sjs_child(St, Sid, Conn),
    %erlang:display({now(), sjs_add, add_sjs_child, timer:now_diff(now(), T1)/1000000}),
    erpher_et:trace_me(50, ?MODULE, ?MODULE, 'cast add finish', {?MODULE, ?LINE}),
    {noreply, St_new};

handle_cast({sjs_del, Sid, Conn}, St) ->
    erpher_et:trace_me(50, ?MODULE, ?MODULE, 'cast del start', {?MODULE, ?LINE}),
    New = del_sjs_pid2(St, Sid, Conn),
    erpher_et:trace_me(50, ?MODULE, ?MODULE, 'cast del finish', {?MODULE, ?LINE}),
    {noreply, New};

handle_cast({sjs_msg, Sid, Conn, Data}, St) ->
    erpher_et:trace_me(50, ?MODULE, ?MODULE, 'cast msg start', {?MODULE, ?LINE}),
    ecomet_sjs:debug(Conn, Data, "ecomet cast debug"),
    New = process_sjs_msg(St, Sid, Conn, Data),
    erpher_et:trace_me(50, ?MODULE, ?MODULE, 'cast msg finish', {?MODULE, ?LINE}),
    {noreply, New};

handle_cast({sjs_broadcast_msg, Data}, St) ->
    New = process_sjs_broadcast_msg(St, Data),
    {noreply, New};

handle_cast(reload_config_signal, St) ->
    New = process_reload_config(St),
    {noreply, New};

handle_cast(_, St) ->
    {noreply, St}.

%%-----------------------------------------------------------------------------
terminate(_Reason, St) ->
    mpln_p_debug:er({?MODULE, ?LINE, terminate, _Reason}),
    ecomet_rb:teardown(St#csr.conn),
    ecomet_sockjs_handler:stop(),
    ok.

%%----------------------------------------------------------------------------
handle_info(_N, State) ->
    mpln_p_debug:er({?MODULE, ?LINE, unknown_request, _N}),
    {noreply, State}.

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
%% @doc requests for creating a new sockjs child
%% @since 2012-01-17 18:11
%%
sjs_add(Sid, Conn) ->
    gen_server:cast(?MODULE, {sjs_add, Sid, Conn}).

%%
%% @doc requests for terminating a sockjs child
%% @since 2012-01-17 18:11
%%
sjs_del(Sid, Conn) ->
    gen_server:cast(?MODULE, {sjs_del, Sid, Conn}).

%%
%% @doc requests for sending a message to a sockjs child
%% @since 2012-01-17 18:11
%%
sjs_msg(Sid, Conn, Data) ->
    gen_server:cast(?MODULE, {sjs_msg, Sid, Conn, Data}).

%%
%% @doc requests for sending a message to all the sockjs children
%% @since 2012-01-23 15:24
%%
sjs_broadcast_msg(Data) ->
    gen_server:cast(?MODULE, {sjs_broadcast_msg, Data}).

%%-----------------------------------------------------------------------------
%%
%% @doc deletes a child from an appropriate list of children
%% @since 2011-11-18 18:00
%%
-spec del_child(pid(), 'sjs', reference()) -> ok.

del_child(Pid, Type, Ref) ->
    gen_server:cast(?MODULE, {del_child, Pid, Type, Ref}).

%%-----------------------------------------------------------------------------

get_stat_procs() ->
    gen_server:call(?MODULE, {get_stat, procs}).

get_stat_procs_mem() ->
    gen_server:call(?MODULE, {get_stat, procs_mem}).

%%-----------------------------------------------------------------------------
reload_config_signal() ->
    gen_server:cast(?MODULE, reload_config_signal).

%%%----------------------------------------------------------------------------
%%% Internal functions
%%%----------------------------------------------------------------------------
%%
%% @doc calls supervisor to create child
%%
-spec do_start_child(reference(), list()) ->
                            {ok, pid()} | {ok, pid(), any()} | {error, any()}.

do_start_child(Id, Pars) ->
    StartFunc = {ecomet_conn_server, start_link, [[Pars]]},
    Child = {Id, StartFunc, temporary, 200, worker, [ecomet_conn_server]},
    supervisor:start_child(ecomet_conn_sup, Child).

%%-----------------------------------------------------------------------------
-spec add_sjs_child(#csr{}, any(), any()) -> {tuple(), #csr{}}.

add_sjs_child(St, Sid, Conn) ->
    Pars = [
            {sjs_sid, Sid},
            {sjs_conn, Conn},
            {no_local, true}, % FIXME: make it a var?
            {type, 'sjs'}
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
    Res = do_start_child(Id, Pars),
    Type = proplists:get_value(type, Ext_pars),
    case Res of
        {ok, Pid} ->
            New_st = add_child_list(St, Type, Pid, Id, Ext_pars),
            {Res, New_st};
        {ok, Pid, _Info} ->
            New_st = add_child_list(St, Type, Pid, Id, Ext_pars),
            {Res, New_st};
        {error, Reason} ->
            mpln_p_debug:er({?MODULE, ?LINE, "start child error", Reason}),
            check_error(St, Reason)
    end.

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
    Crb = prepare_rabbit(C),
    prepare_part(Crb).

%%
%% @doc prepares almost all the necessary things, except rabbit
%%
-spec prepare_part(#csr{}) -> #csr{}.

prepare_part(C) ->
    prepare_log(C),
    ecomet_sockjs_handler:start(C),
    C.

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
%% @doc tries to reconnect to rabbit in case of do_start_child returns noproc,
%% which means the connection to rabbit is closed.
%% @todo decide which policy is better - connection restart or terminate itself
%%
check_error(St, {{noproc, _Reason}, _Other}) ->
    mpln_p_debug:er({?MODULE, ?LINE, 'check_error noproc, reconnect to rabbit'}),
    New = reconnect(St),
    {{error, noproc}, New};
check_error(St, Other) ->
    mpln_p_debug:ir({?MODULE, ?LINE, check_error_other}),
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
%% @doc adds child info into appropriate list - either web socket or long poll
%% in dependence of given child type.
%%
-spec add_child_list(#csr{}, 'sjs', pid(), reference(),
                     list()) -> #csr{}.

add_child_list(St, Type, Pid, Id, Pars) ->
    Id_web = proplists:get_value(id_web, Pars),
    Data = #chi{pid=Pid, id=Id, id_web=Id_web, start=now()},
    add_child_list2(St, Type, Data, Pars).

add_child_list2(#csr{sjs_children=C} = St, 'sjs', Data, Pars) ->
    Sid = proplists:get_value(sjs_sid, Pars),
    St#csr{sjs_children=[{Sid, Data} | C]}.

%%-----------------------------------------------------------------------------
%%
%% @doc deletes sockjs related process from a list of children and terminates
%% them
%%
del_sjs_pid2(St, Ref, Conn) ->
    % gives an exception when trying to close already closed session
    Res = (catch sockjs:close(3000, "conn. closed.", Conn)),
    mpln_p_debug:pr({?MODULE, 'del_sjs_pid2', ?LINE, Ref, Conn, Res}, St#csr.debug, run, 3),
    F = fun({X, _}) ->
                X == Ref
        end,
    proceed_del_sjs_pid(St, F).

del_sjs_pid(St, _Pid, Ref) ->
    mpln_p_debug:pr({?MODULE, 'del_sjs_pid', ?LINE, Ref, _Pid}, St#csr.debug, run, 2),
    F = fun({_, #chi{id=Id}}) ->
                Id == Ref
        end,
    proceed_del_sjs_pid(St, F).

-spec proceed_del_sjs_pid(#csr{}, fun()) -> #csr{}.

proceed_del_sjs_pid(#csr{sjs_children=L} = St, F) ->
    {Del, Cont} = lists:partition(F, L),
    mpln_p_debug:pr({?MODULE, 'proceed_del_sjs_pid', ?LINE, Del, Cont}, St#csr.debug, run, 5),
    terminate_sjs_children(St, Del),
    St#csr{sjs_children = Cont}.

%%-----------------------------------------------------------------------------
%%
%% @doc terminates sockjs or socket-io related process
%%
terminate_sjs_children(St, List) ->
    F = fun({_, #chi{pid=Pid}}) ->
                Info = process_info(Pid),
                mpln_p_debug:pr({?MODULE, terminate_children, ?LINE, Info}, St#csr.debug, run, 5),
                ecomet_conn_server:stop(Pid)
        end,
    lists:foreach(F, List).

%%-----------------------------------------------------------------------------
%%
%% @doc sends data to every sockjs child
%%
process_sjs_broadcast_msg(#csr{sjs_children=Ch} = St, Data) ->
    erpher_et:trace_me(50, ?MODULE, ecomet_conn_server, data_from_server, {?MODULE, ?LINE, length(Ch)}),
    [ecomet_conn_server:data_from_server(Pid, Data) || #chi{pid=Pid} <- Ch],
    St.

%%-----------------------------------------------------------------------------
%%
%% @doc creates a handler process if it's not done yet, charges the process
%% to do the work
%%
process_sjs_msg(#csr{smoke_test={random, _}} = St, Sid, _Conn, Data) ->
    erpher_et:trace_me(30, ?MODULE, undefined, smoke_test_random, Data),
    send_return_msg(St, Sid, Data),
    process_sjs_multicast_msg(St, Data);

process_sjs_msg(#csr{smoke_test=broadcast} = St, _Sid, _Conn, Data) ->
    erpher_et:trace_me(30, ?MODULE, undefined, smoke_test_broadcast, Data),
    process_sjs_broadcast_msg(St, Data);

process_sjs_msg(St, Sid, Conn, Data) ->
    %T1 = now(),
    ecomet_sjs:debug(Conn, Data, "pre check_sjs_child debug"),
    Check = check_sjs_child(St, Sid, Conn),
    ecomet_sjs:debug(Conn, Data, "post check_sjs_child debug"),
    %erlang:display({now(), process_sjs_msg, checkChild, timer:now_diff(now(), T1)/1000000}),
    case Check of
        {{ok, Pid}, St_c} ->
            erpher_et:trace_me(50, ?MODULE, ecomet_conn_server, data_from_sjs, {?MODULE, ?LINE}),
            ecomet_conn_server:data_from_sjs(Pid, Data),
            St_c;
        {{ok, Pid, _}, St_c} ->
            erpher_et:trace_me(50, ?MODULE, ecomet_conn_server, data_from_sjs, {?MODULE, ?LINE}),
            ecomet_conn_server:data_from_sjs(Pid, Data),
            St_c;
        {{error, _Reason}, _St_c} ->
            mpln_p_debug:er({?MODULE, ?LINE, process_sjs_msg, {error, _Reason}}),
            St
    end.

%%-----------------------------------------------------------------------------
%%
%% @doc checks whether the sockjs child with given id is alive. Creates
%% the one if it's not.
%%
-spec check_sjs_child(#csr{}, any(), any()) ->
                            {{ok, pid()}, #csr{}}
                                | {{ok, pid(), any()}, #csr{}}
                                | {{error, any()}, #csr{}}.

check_sjs_child(#csr{sjs_children = Ch} = St, Sid, Conn) ->
    case is_sjs_child_alive(St, Ch, Sid) of
        {true, I} ->
            {{ok, I#chi.pid}, St};
        {false, _} ->
            add_sjs_child(St, Sid, Conn)
    end.

%%-----------------------------------------------------------------------------
%%
%% @doc finds sockjs child with given client id and checks whether it's
%% alive
%%
is_sjs_child_alive(St, List, Sjs_sid) ->
    Child = proplists:get_value(Sjs_sid, List),
    case Child of
        undefined ->
            {false, undefined};
        _ ->
            {true, Child}
    end.

%%-----------------------------------------------------------------------------
%%
%% @doc deletes a child from a list of children
%%
del_child_pid(St, Pid, 'sjs', Ref) ->
    del_sjs_pid(St, Pid, Ref).

%%
%% @doc returns number of running comet processes
%%
prepare_stat_result(#csr{sjs_children=Ch}, procs) ->
    length(Ch);

%%
%% @doc returns number of running comet processes and their memory
%% consumption. This does not include memory of sockjs and webserver
%% processes.
%%
prepare_stat_result(#csr{sjs_children=Ch}, procs_mem) ->
    Len = length(Ch),
    Pids = [X#chi.pid || X <- Ch],
    Sum = estat_misc:fetch_sum_pids_memory(Pids),
    [{prc, Len}, {mem, Sum}].

%%-----------------------------------------------------------------------------
%%
%% @doc fetches config from updated environment and stores it in the state
%%
-spec process_reload_config(#csr{}) -> #csr{}.

process_reload_config(St) ->
    ecomet_sockjs_handler:stop(),
    C = ecomet_conf:get_config(St),
    prepare_part(C).

%%-----------------------------------------------------------------------------
%%
%% @doc find sockjs connection with given id
%%
find_sjs(#csr{sjs_children = Ch} = St, Sid) ->
    case is_sjs_child_alive(St, Ch, Sid) of
        {true, I} ->
            {ok, I#chi.pid};
        {false, _} ->
            error
    end.

%%-----------------------------------------------------------------------------
%%
%% @doc send received message back to the originator
%%
send_return_msg(St, Sid, Data) ->
    case find_sjs(St, Sid) of
        {ok, Pid} ->
            ecomet_conn_server:data_from_sjs(Pid, Data);
        error ->
            ok
    end.

%%-----------------------------------------------------------------------------
%%
%% @doc send message to N random sockjs connections
%%
process_sjs_multicast_msg(#csr{sjs_children=[]} = St, _) ->
    St;

process_sjs_multicast_msg(#csr{smoke_test={random, N}, sjs_children=Ch} = St,
                          Data) ->
    Len = length(Ch),
    F = fun(_) ->
        Idx = crypto:rand_uniform(0, Len),
        #chi{pid=Pid} = lists:nth(Idx + 1, Ch),
        ecomet_conn_server:data_from_sjs(Pid, Data)
    end,
    lists:foreach(F, lists:duplicate(N, true)),
    St.

%%-----------------------------------------------------------------------------
