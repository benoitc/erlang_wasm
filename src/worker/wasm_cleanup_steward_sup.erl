-module(wasm_cleanup_steward_sup).
-moduledoc """
Internal: the dynamic supervisor for per-request cleanup stewards.

One steward exists per in-flight request. The cleanup manager starts them here
and monitors each one; they are temporary, because a steward that exits has
either finished its request or been replaced, and neither is something to
restart under it. See `test/audit/CLEANUP_STEWARD.md`.
""".

-behaviour(supervisor).

-export([start_link/0, init/1, start_steward/1]).

-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    Flags = #{strategy => simple_one_for_one, intensity => 0, period => 1},
    Child = #{id => wasm_cleanup_steward,
              start => {wasm_cleanup_steward, start_link, []},
              restart => temporary,
              shutdown => 5000,
              type => worker,
              modules => [wasm_cleanup_steward]},
    {ok, {Flags, [Child]}}.

-doc "Start a steward for a request. Its argument is the steward's own.".
-spec start_steward(term()) -> supervisor:startchild_ret().
start_steward(Arg) ->
    supervisor:start_child(?MODULE, [Arg]).
