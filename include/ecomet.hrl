-ifndef(ecomet_params).
-define(ecomet_params, true).

-record(cli, {
    from,
    start={0,0,0} % time in now() format
}).

-record(chi, {
    pid,
    id,
    id_web,
    sjs_sid,
    sjs_conn,
    start={0,0,0} % time in now() format
}).

-endif.
