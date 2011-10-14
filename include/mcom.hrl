-ifndef(mcom_params).
-define(mcom_params, true).

-define(T, 1000).
-define(TC, 0).
-define(LOG, "/var/log/erpher/mc").
-define(CONF, "mcom.conf").

% state of a websocket worker
-record(child, {
    name,
    port,
    id,
    os_pid,
    duration,
    from,
    method,
    url,
    host,
    auth,
    url_rewrite,
    params,
    debug
}).

-record(chi, {
    pid,
    id,
    mon,
    os_pid,
    start={0,0,0} % time in now() format
}).

% state of a server server
-record(csr, {
    children = [],
    log,
    debug
}).

-endif.
