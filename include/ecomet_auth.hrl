-include("ecomet_nums.hrl").

-ifndef(ecomet_auth).
-define(ecomet_auth, true).

% state of a auth worker
-record(auth_cnf, {
    http_connect_timeout = ?HTTP_CONNECT_TIMEOUT,
    http_timeout = ?HTTP_TIMEOUT, % timeout for http auth queries
    use_cache = true,
    cache_lt = 600 % cache lifetime, s
}).

-record(auth_st, {
    config = #auth_cnf{},
    cache = [],
    last_reset
}).

-endif.
