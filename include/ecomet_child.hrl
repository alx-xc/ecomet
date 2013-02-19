-include("ecomet_nums.hrl").

-ifndef(ecomet_child).
-define(ecomet_child, true).

% state of a websocket worker
-record(child, {
    id, % ref
    id_r, % rand id for simulating no_local amqp consumer
    id_web, % rand id from long poll web page
    id_s, % user id to match messages from amqp (used in socket-io, sockjs part)
    start_time = {0,0,0},
    last_use = {0,0,0},
    idle_timeout = ?IDLE_TIMEOUT,
    auth_last = {0,0,0},
    auth_recheck = ?AUTH_RECHECK_INTERVAL,
    auth_url,
    auth_host,
    auth_cookie,
    sjs_sid,
    sjs_conn,
    clients = [], % in case of many requests with the very same id (quite unusual not to say sabotage)
    queue,
    qmax_dur = ?QUEUE_MAX_DUR, % microseconds
    qmax_len = ?QUEUE_MAX_LEN,
    debug,
    conn, % #conn{}
    exchange_base,
    routes = [], % routing keys
    no_local = false, % for amqp consumer setup
    type :: 'sjs', % web socket, long polling, socket-io, sockjs
    user_data_as_auth_host :: undefined | boolean(),
    event,
    timer :: reference(), % timer for periodic checks
    timer_idle :: reference(), % timer for idle checks
    economize  :: hibernate | infinity, % gen_server default policy
    deep_memory_economize = true :: boolean() % call gc on linked cowboy pids
}).

-endif.
