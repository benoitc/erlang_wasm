-module(arb_inst).
%% Scratch first-write counters, compiled only into the instrumented trees
%% (erlang_wasm-arb-inst-*), never into a timed arm. Off until init/0.
-export([init/0, on/0, add/3, read/0]).

init() ->
    case on() of
        false -> persistent_term:put(?MODULE, counters:new(4, [write_concurrency]));
        _ -> ok
    end.

on() -> persistent_term:get(?MODULE, false).

add(C, fault, Ns) -> counters:add(C, 1, 1), counters:add(C, 2, Ns);
add(C, buy, Ns) -> counters:add(C, 3, 1), counters:add(C, 4, Ns).

read() ->
    C = on(),
    Base = #{fault_n => counters:get(C, 1), fault_ns => counters:get(C, 2),
             buy_n => counters:get(C, 3), buy_ns => counters:get(C, 4)},
    case code:ensure_loaded(wasm_mem_nif) =:= {module, wasm_mem_nif}
        andalso erlang:function_exported(wasm_mem_nif, arb_firstwrite, 0) of
        true ->
            {Pages, Writes, Ns} = wasm_mem_nif:arb_firstwrite(),
            Base#{newbit_pages => Pages, newbit_writes => Writes,
                  newbit_ns => Ns};
        false ->
            Base
    end.
