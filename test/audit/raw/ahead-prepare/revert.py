import sys
which=sys.argv[1]
W='/Users/benoitc/Projects/erlang_wasm/src/worker/wasm_script_worker.erl'
M='/Users/benoitc/Projects/erlang_wasm/src/wasm_memory.erl'
edits={
 '1':(W,"prepare_mems(Mems, Set, Need, go)","prepare_mems(Mems, Set, Need, stop)"),
 '2':(W,"""            Written = ordsets:subtract(wasm_memory:written_pages(M),
                                       Unchanged),""","""            _ = Unchanged, Written = wasm_memory:written_pages(M),"""),
 '3':(W,"""    idle() andalso
        wasm_engine:page_limit()""","""        wasm_engine:page_limit()"""),
 '4':(W,"""    idle() andalso
        wasm_engine:page_limit() - wasm_engine:pages_in_use() >= Need.""","""    _ = Need, idle()."""),
 '5':(M,"""    wasm_error:capture(fun() -> _ = ensure_private(M, P), ok end);""","""    _ = ensure_private(M, P), ok;"""),
 '6':(W,"""    [{Ix, M} || {Ix, M} <- lists:enumerate(0, Mems),
                not wasm_memory:is_shared(M)].""","""    lists:enumerate(0, Mems)."""),
}
f,a,b=edits[which]
s=open(f).read(); assert a in s, which; open(f,'w').write(s.replace(a,b,1))
