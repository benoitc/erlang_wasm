#!/usr/bin/env python3
# Instrument a scratch tree for gate 5. Never a timed arm.
#   inst.py cand TREE   log each request's prepared pages and its sample
#   inst.py main TREE   log each request's private pages before the destroy
# Both append `{Tag, Pages}.` terms (memory 0) to the file $AP_LOG names.
import sys
arm, tree = sys.argv[1], sys.argv[2]
W = tree + '/src/worker/wasm_script_worker.erl'
M = tree + '/src/wasm_memory.erl'
LOG = '''
ap_log(Tag, T) ->
    case os:getenv("AP_LOG") of
        false -> ok;
        F -> ok = file:write_file(F, io_lib:format("~w.~n", [{Tag, T}]),
                                  [append])
    end.
'''
s = open(W).read()
if arm == 'cand':
    a = """            put(?USED, [{Ix, current(M), Ps} || {Ix, M, Ps} <- Done]),
            ok;"""
    b = """            put(?USED, [{Ix, current(M), Ps} || {Ix, M, Ps} <- Done]),
            ok = ap_log(prepared, lists:append([lists:sort(Ps)
                                                || {0, _, Ps} <- Done])),
            ok;"""
    assert a in s; s = s.replace(a, b, 1)
    a = """            put(?SAMPLES, Samples),"""
    b = """            ok = ap_log(sample, maps:get(0, Sample, [])),
            put(?SAMPLES, Samples),"""
    assert a in s; s = s.replace(a, b, 1)
    a = """        interrupted ->
            ok;"""
    b = """        interrupted ->
            ap_log(sample, interrupted);"""
    assert a in s; s = s.replace(a, b, 1)
else:
    a = """            R = invoke_loop(Invoke, Inst, Limits, G#g.adapter, AState),
            ok = destroy_instance(Runtime, Inst),"""
    b = """            R = invoke_loop(Invoke, Inst, Limits, G#g.adapter, AState),
            ok = ap_log(written, wasm_memory:written_pages(
                                   wasm_instance:memory(Inst, 0))),
            ok = destroy_instance(Runtime, Inst),"""
    assert a in s; s = s.replace(a, b, 1)
    m = open(M).read()
    m = m.replace("-export([store_r/4, refresh/1, image/1]).",
                  "-export([store_r/4, refresh/1, image/1]).\n-export([written_pages/1]).", 1)
    a = """-doc \"\"\"
The memory as an image: one immutable binary per 64 KiB page, or `zero`."""
    b = '''written_pages(#mem{img_bytes = 0}) -> [];
written_pages(#mem{tab = Tab, img_bytes = IB}) ->
    [P || P <- lists:seq(0, (IB bsr ?SLOT_SHIFT) - 1),
          atomics:get(Tab, P + 1) =/= 0].

''' + a
    assert a in m; m = m.replace(a, b, 1)
    open(M, 'w').write(m)
s = s.rstrip('\n') + '\n' + LOG
open(W, 'w').write(s)
print('instrumented', arm, tree)
