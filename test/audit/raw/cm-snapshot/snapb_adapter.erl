-module(snapb_adapter).
%% The gate fixtures through the worker, with or without an image: options
%% `fixture' (statecore | twocore | realupper) and `image' (true | false).
%% `realupper' gets this request's stdin and stdout, and the host_remake that
%% makes its stdio again from them.
-behaviour(wasm_worker_adapter).
-export([artifact/1, requirements/2, prepare/3, decode/2, cleanup/1,
         capabilities/1, conformance_fixtures/1, classify/2, snapshot_capability/1]).

artifact(Opts) ->
    F = maps:get(fixture, Opts),
    {ok, Bin} = file:read_file(filename:join([code:lib_dir(wasm), "..", "..", "..", "..",
                                              "test", "fixtures", "component",
                                              atom_to_list(F) ++ ".component.wasm"])),
    {ok, #{bin => Bin, fixture => F, image => maps:get(image, Opts, false)}}.

requirements(R, _A) ->
    {ok, #{min_timeout => 1000, min_memory_pages => 1, request_bytes => erlang:external_size(R),
           staged_bytes => 0, staged_files => 0, mounts => #{}}}.

prepare(_R, #{bin := Bin, fixture := F, image := Image}, _Env) ->
    {Imports, State} = request_imports(F, Image),
    {ok, #{mode => reactor, runtime => component, module => Bin, imports => Imports,
           invoke => [invoke(F)]}, State}.

%% The cold arm calls nothing main does not have.
request_imports(realupper, Image) ->
    T = ets:new(out, [public]),
    O = #{stdin => <<"hello">>, stdout => fun(B) -> ets:insert(T, {B}), ok end},
    Base = #{bindings => wasi_preview2:command(O), compatibility_key => <<"snapb">>},
    {case Image of
         true -> Base#{snapshot_hooks => wasi_preview2:snapshot_hooks(),
                       host_remake => wasi_preview2:host_remake(O)};
         false -> Base#{snapshot_hooks => #{}}
     end, T};
request_imports(_, _Image) ->
    {#{bindings => #{}, snapshot_hooks => #{}, compatibility_key => <<"snapb">>}, none}.

invoke(statecore) -> {call, <<"bump">>, {[], u32}, []};
invoke(twocore) -> {call, <<"run">>, {[], u32}, []};
invoke(realupper) -> {call, <<"wasi:cli/run@0.2.0#run">>, {[], {result, none, none}}, []}.

snapshot_capability(#{image := false}) -> unsupported;
snapshot_capability(#{bin := Bin, fixture := F}) ->
    {Imports, _} = capture_imports(F),
    #{version => <<"snapb-1">>, runtime => component, module => Bin, imports => Imports,
      init => [], validate => fun(_) -> ok end, post_restore => fun(_, _) -> ok end}.

capture_imports(realupper) ->
    {#{bindings => wasi_preview2:command(#{}), snapshot_hooks => wasi_preview2:snapshot_hooks(),
       compatibility_key => <<"snapb">>}, none};
capture_imports(F) -> request_imports(F, true).

decode(#{outcome := returned}, _S) -> {ok, done};
decode(#{outcome := trapped, error := E}, _S) -> {error, wasm_worker_error:runtime(E)};
decode(#{outcome := exited}, _S) -> {ok, done}.

cleanup(none) -> ok;
%% The table can be gone already, with the process that made it.
cleanup(T) ->
    try ets:delete(T) catch error:badarg -> ok end,
    ok.

capabilities(#{image := I}) ->
    #{execution => reactor, input_channels => [typed_args], result_channels => [typed_result],
      snapshots => case I of true -> #{version => <<"snapb-1">>}; false -> unsupported end,
      wasi => false}.

conformance_fixtures(_A) -> #{base => #{}, by_capability => #{}}.
classify({ok, _}, _S) -> continue;
classify({error, _}, _S) -> {stop, trapped}.
