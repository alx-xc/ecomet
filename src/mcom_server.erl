%%%----------------------------------------------------------------------------
%%% server to create children that serve new websocket requests
%%%----------------------------------------------------------------------------

-module(mcom_server).
-behaviour(gen_server).

%%%----------------------------------------------------------------------------
%%% Exports
%%%----------------------------------------------------------------------------

-export([start/0, start_link/0, stop/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).
-export([terminate/2, code_change/3]).
-export([add/1, add/2]).

%%%----------------------------------------------------------------------------
%%% Includes
%%%----------------------------------------------------------------------------

-include("mcom.hrl").

%%%----------------------------------------------------------------------------
%%% gen_server callbacks
%%%----------------------------------------------------------------------------

init(_) ->
    C = mcom_conf:get_config(),
    New = prepare_all(C),
    [application:start(X) || X <- [sasl, crypto, public_key, ssl]], % FIXME
    mpln_p_debug:pr({'init done', ?MODULE, ?LINE}, New#csr.debug, run, 1),
    {ok, New, ?T}.

%%-----------------------------------------------------------------------------
handle_call({add, Event, No_local}, _From, St) ->
    mpln_p_debug:pr({?MODULE, 'add_child', ?LINE}, St#csr.debug, run, 2),
    {Res, New} = add_child(St, Event, No_local),
    {reply, Res, New, ?T};
handle_call(status, _From, St) ->
    {reply, St, St, ?T};
handle_call(stop, _From, St) ->
    {stop, normal, ok, St};
handle_call(_N, _From, St) ->
    {reply, {error, unknown_request}, St, ?T}.

%%-----------------------------------------------------------------------------
handle_cast(stop, St) ->
    {stop, normal, St};
handle_cast(_, St) ->
    {noreply, St, ?T}.

%%-----------------------------------------------------------------------------
terminate(_, _State) ->
    yaws:stop(),
    ok.

%%-----------------------------------------------------------------------------
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
add(Event) ->
    add(Event, true).

%%-----------------------------------------------------------------------------
add(Event, true) ->
    gen_server:call(?MODULE, {add, Event, true});
add(Event, _) ->
    gen_server:call(?MODULE, {add, Event, false}).

%%%----------------------------------------------------------------------------
%%% Internal functions
%%%----------------------------------------------------------------------------

-spec do_start_child(reference(), list()) ->
                            {ok, pid()} | {ok, pid(), any()} | {error, any()}.

do_start_child(Id, Pars) ->
    Ch_conf = [Pars],
    StartFunc = {mcom_conn_server, start_link, [Ch_conf]},
    Child = {Id, StartFunc, temporary, 1000, worker, [mcom_conn_server]},
    supervisor:start_child(mcom_conn_sup, Child).

%%-----------------------------------------------------------------------------
-spec add_child(#csr{}, any(), boolean()) -> {{ok, pid()}, #csr{}}
                           | {{ok, pid(), any()}, #csr{}}
                           | {error, #csr{}}.

add_child(St, Event, No_local) ->
    Id = make_ref(),
    Pars = [{id, Id}, {event, Event}, {no_local, No_local}, {conn, St#csr.conn}
            | St#csr.child_config],
    Res = do_start_child(Id, Pars),
    mpln_p_debug:pr({?MODULE, "start child result", ?LINE, Id, Pars, Res},
                    St#csr.debug, child, 4),
    case Res of
        {ok, Pid} ->
            Ch = [{Pid, Id} | St#csr.children],
            {Res, St#csr{children = Ch}};
        {ok, Pid, _Info} ->
            Ch = [{Pid, Id} | St#csr.children],
            {Res, St#csr{children = Ch}};
        {error, Reason} ->
            mpln_p_debug:pr({?MODULE, "start child error", ?LINE, Reason},
                            St#csr.debug, child, 1),
            check_error(St, Reason)
    end.

%%-----------------------------------------------------------------------------
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
    New = prepare_rabbit(C),
    start_yaws(C),
    New.

%%-----------------------------------------------------------------------------
%%
%% @doc prepares rabbit connection
%%
-spec prepare_rabbit(#csr{}) -> #csr{}.

prepare_rabbit(C) ->
    Conn = mcom_rb:start(C#csr.rses),
    C#csr{conn=Conn}.

%%-----------------------------------------------------------------------------
check_error(St, {{noproc, _Reason}, _Other}) ->
    mpln_p_debug:pr({?MODULE, "check_error", ?LINE}, St#csr.debug, run, 2),
    New = reconnect(St),
    mpln_p_debug:pr({?MODULE, "check_error new st", ?LINE, New}, St#csr.debug, run, 2),
    {error, New};
check_error(St, _Other) ->
    mpln_p_debug:pr({?MODULE, "check_error other", ?LINE}, St#csr.debug, run, 2),
    {error, St}.

%%-----------------------------------------------------------------------------
reconnect(St) ->
    mcom_rb:teardown_conn(St#csr.conn),
    prepare_rabbit(St).

%%-----------------------------------------------------------------------------
