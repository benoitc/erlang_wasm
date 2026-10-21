-module(fake_http_transport).
-moduledoc """
A `wasi_http_transport` that makes no connection: it sends the request it was
given to the calling process and answers 200.

The guest's request is performed in the process running the guest, so a test
that runs a command reads `{fake_http_request, Req}` from its own mailbox and
can assert what the host would have connected to, or that it connected to
nothing.
""".

-behaviour(wasi_http_transport).

-export([request/2]).

request(Req, _Timeout) ->
    self() ! {fake_http_request, Req},
    {ok, 200, [], <<>>}.
