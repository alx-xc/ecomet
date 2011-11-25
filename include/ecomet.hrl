-ifndef(ecomet_params).
-define(ecomet_params, true).

-record(cli, {
    from,
    start={0,0,0} % time in now() format
}).

-record(yp, { % yaws process serving long poll
    pid,
    start={0,0,0} % time in now() format
}).

-record(chi, {
    pid,
    id,
    id_web,
    sio_mgr,
    sio_cli,
    sio_sid,
    start={0,0,0} % time in now() format
}).

-endif.
