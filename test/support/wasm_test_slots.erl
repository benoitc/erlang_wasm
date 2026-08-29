-module(wasm_test_slots).
-moduledoc """
Putting the code slots back between cases.

Cases that drive the compiled tier leave code loaded, rows filled and call
counters raised, and a case that leaked a counter would take a slot out of the
pool for every case after it. Resetting the rows is not enough on its own: a
call lease lives in an `atomics` array rather than in the table, so the case
that deliberately leaks them would otherwise wedge the whole suite.

Copied into two suites before it was here.
""".
-export([reset/0]).

-doc "Free every slot, unload its code, and drain its call counter.".
-spec reset() -> ok.
reset() ->
    Counters = persistent_term:get({wasm_code_slots, counters}, undefined),
    [begin
         _ = code:purge(Name), _ = code:delete(Name), _ = code:purge(Name),
         true = ets:insert(wasm_code_slots, {Name, 0, free, #{}}),
         Counters =:= undefined orelse atomics:put(Counters, Ix, 0)
     end || {Ix, Name} <- lists:enumerate(wasm_code_slots:slots())],
    ok.
