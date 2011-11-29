-include("ecomet_nums.hrl").

-ifndef(ecomet_child).
-define(ecomet_child, true).

% state of a websocket worker
-record(child, {
    id, % ref
    id_r, % rand id for simulating no_local amqp consumer
    id_web, % rand id from long poll web page
    id_q, % user id to match messages from amqp (used in socket-io part)
    start_time = {0,0,0},
    last_use = {0,0,0},
    idle_timeout = ?IDLE_TIMEOUT,
    lp_request_timeout = ?LP_REQUEST_TIMEOUT,
    sock,
    lp_sock, % for long poll
    sio_mgr, % socket-io event manager
    sio_hdl, % socket-io handler (module, in fact)
    sio_cli, % socket-io client
    sio_sid, % socket-io session id
    yaws_pid, % for long poll
    clients = [], % in case of many requests with the very same id (quite unusual not to say sabotage)
    queue,
    qmax_dur = ?QUEUE_MAX_DUR, % microseconds
    qmax_len = ?QUEUE_MAX_LEN,
    debug,
    conn, % #conn{}
    exchange_base,
    no_local = false, % for amqp consumer setup
    type :: 'ws' | 'lp' | 'sio', % web socket, long polling, socket-io
    http_connect_timeout = ?HTTP_CONNECT_TIMEOUT,
    http_timeout = ?HTTP_TIMEOUT,
    event,
    stat % #stat{}
}).

-endif.