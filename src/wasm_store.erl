-module(wasm_store).
-moduledoc """
Owns every long-lived ETS table, and does nothing else.

The tables outlive the processes that use them. `wasm_keeper`'s registry decides
whether pages ever come back, `wasm_engine`'s store holds every table's
contents and every shared global's value, and `wasm_code_slots`' tables say
which generated module names are in use. A server that created its own would
take that state down with it on every restart and come back believing the node
held nothing.

They used to belong to `wasm_sup`, which gave them the right lifetime against a
*child* crash and the wrong one against anything else: the root supervisor is
also the process every subsystem hangs off, so it is the process most likely to
be restarted, and it took the registry with it. This module is the owner
instead, so the tables survive any subsystem's supervisor being restarted, and
`wasm_sup` goes back to supervising.

## Why the heir is the supervisor

`wasm_store_sup` is named as each table's heir. It is found by name rather than
passed in, because a supervisor registers its name before it starts any child,
so it is already resolvable from here and there is nothing to thread through
`wasm_sup`'s child specs.

Naming it as heir means this process crashing hands the tables over rather than
destroying them. The supervisor then owns them,
which is exactly the arrangement that worked before, and the replacement
`wasm_store` finds them already there: every `ensure_*` function it calls is a
no-op on an existing table, so it simply leaves them where they are. There is no
give-away dance and nothing to get wrong on the way back.

The cost is one `"Supervisor received unexpected message"` error report per
transfer, because an OTP supervisor has no `handle_info` for `ETS-TRANSFER`.
That is the right trade: this process holds tables and runs no logic, so it does
not crash on its own, and one noisy report beats losing the node's resource
accounting.

## What it deliberately does not cover

Nothing inside a supervision tree survives the root of that tree dying. If
`wasm_sup` goes, the heir goes with it and the tables go too. That case is made
*harmless* rather than impossible, by `wasm_keeper` reconciling the page counter
against the registry when it starts: a lost registry then reads as a clean
reset instead of a permanent leak. See `wasm_keeper:init/1`.
""".
-behaviour(gen_server).

-export([start_link/0, tables/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

%% Named rather than derived, because a table this does not know about is one
%% nothing gives a lifetime to. Adding a long-lived table means adding it here.
-define(TABLES, [wasm_holders, wasm_tables, wasm_waiters,
                 wasm_code_slots, wasm_code_calls]).

-spec start_link() -> {ok, pid()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-doc "The tables this owns. For diagnostics and for the architecture suite.".
-spec tables() -> [atom()].
tables() -> ?TABLES.

init([]) ->
    %% Each of these is idempotent and each belongs to the module that reads it,
    %% so the knowledge of what a table holds stays there and only the lifetime
    %% is decided here.
    ok = wasm_keeper:ensure_table(),
    ok = wasm_engine:ensure_store(),
    ok = wasm_engine:ensure_waiter_table(),
    ok = wasm_code_slots:ensure_table(),
    Heir = whereis(wasm_store_sup),
    _ = [bequeath(T, Heir) || T <- ?TABLES, is_pid(Heir)],
    {ok, Heir}.

%% Only a table this process actually created. After a transfer the supervisor
%% owns them and setting an heir from here would fail, which is the ordinary
%% case on every restart after the first crash.
bequeath(Tab, Heir) ->
    case ets:info(Tab, owner) of
        Owner when Owner =:= self() ->
            true = ets:setopts(Tab, {heir, Heir, ?MODULE}),
            ok;
        _ ->
            ok
    end.

handle_call(_Req, _From, State) -> {reply, {error, unknown_call}, State}.
handle_cast(_Msg, State) -> {noreply, State}.
handle_info(_Info, State) -> {noreply, State}.
