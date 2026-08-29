-module(wasm_error).
-moduledoc """
Structured errors and traps.

Read this when you are deciding what to match on. Every failure you get back
from the runtime is one of five classes, matching the distinctions the
WebAssembly specification test suite draws:
- `malformed`   - the binary could not be decoded (`assert_malformed`)
- `invalid`     - it decoded but failed validation (`assert_invalid`)
- `link`        - instantiation failed (`assert_unlinkable`)
- `trap`        - execution trapped (`assert_trap`)
- `exhaustion`  - a resource limit was hit (`assert_exhaustion`)
Match on `class` and `kind`; both are atoms and neither is derived from module
data. `msg` carries the canonical specification message text, so the spec driver
can compare it against the expected failure, and `ctx` carries enough to
diagnose a module: which function, which byte offset, and the enclosing block
path. Use `format/1` for logs.

Inside the library the decoder and validator signal by `throw/1` rather than
threading `{ok, _} | {error, _}` through every combinator, which keeps the hot
paths free of result-tuple allocation. `capture/1` converts back to a value at
the API boundary, so no throw ever reaches you.
""".

-export([malformed/2, malformed/3,
         invalid/2, invalid/3,
         link_error/2, link_error/3,
         trap/1, trap/2,
         exhaustion/1, exhaustion/2]).
-export([capture/1, capture/2, format/1, is_error/1]).
-export([add_context/2]).

-export_type([class/0, error/0, trap_reason/0]).

-type class() :: malformed | invalid | link | trap | exhaustion.

-type error() :: #{class := class(),
                   kind  := atom(),
                   msg   := binary(),
                   ctx   := map()}.

-type trap_reason() :: unreachable
                     | integer_divide_by_zero
                     | integer_overflow
                     | invalid_conversion_to_integer
                     | out_of_bounds_memory_access
                     | out_of_bounds_table_access
                     | undefined_element
                     | uninitialized_element
                     | indirect_call_type_mismatch
                     | {host_error, term()}.

%%% ---------------------------------------------------------- constructors ---

-doc """
Throw: the bytes are not a well-formed module.

Decoding only. A module that decodes but does not type check is `invalid/2`,
and the distinction is what the specification suite asserts on: `assert_malformed`
and `assert_invalid` are different directives.
""".
-spec malformed(atom(), binary()) -> no_return().
malformed(Kind, Msg) -> malformed(Kind, Msg, #{}).

-doc "As `malformed/2`, carrying context for the report.".
-spec malformed(atom(), binary(), map()) -> no_return().
malformed(Kind, Msg, Ctx) -> raise(malformed, Kind, Msg, Ctx).

-doc "Throw: the module decodes but does not validate.".
-spec invalid(atom(), binary()) -> no_return().
invalid(Kind, Msg) -> invalid(Kind, Msg, #{}).

-doc "As `invalid/2`, carrying context for the report.".
-spec invalid(atom(), binary(), map()) -> no_return().
invalid(Kind, Msg, Ctx) -> raise(invalid, Kind, Msg, Ctx).

-doc "Throw: instantiation cannot satisfy an import. Nothing has run yet.".
-spec link_error(atom(), binary()) -> no_return().
link_error(Kind, Msg) -> link_error(Kind, Msg, #{}).

-doc "As `link_error/2`, carrying context for the report.".
-spec link_error(atom(), binary(), map()) -> no_return().
link_error(Kind, Msg, Ctx) -> raise(link, Kind, Msg, Ctx).

-doc """
Throw: the guest did something the specification says traps.

A trap is defined behaviour, not a defect. Every one of them is reachable from
valid WebAssembly and an embedder should expect them.
""".
-spec trap(trap_reason()) -> no_return().
trap(Reason) -> trap(Reason, #{}).

-doc "As `trap/1`, carrying context for the report.".
-spec trap(trap_reason(), map()) -> no_return().
trap(Reason, Ctx) -> raise(trap, reason_kind(Reason), trap_msg(Reason), Ctx).

-doc """
Throw: a limit stopped the guest, rather than the guest doing something wrong.

Fuel, call depth, memory pages and host calls all arrive here. Distinct from a
trap because the module is not at fault and the same call under a larger budget
would succeed.
""".
-spec exhaustion(atom()) -> no_return().
exhaustion(Kind) -> exhaustion(Kind, #{}).

-doc "As `exhaustion/1`, carrying context for the report.".
-spec exhaustion(atom(), map()) -> no_return().
exhaustion(Kind, Ctx) -> raise(exhaustion, Kind, exhaustion_msg(Kind), Ctx).

%% Declared `no_return' so callers are understood to end here rather than
%% falling through: the decoder and validator signal by throwing.
-spec raise(class(), atom(), binary(), map()) -> no_return().
raise(Class, Kind, Msg, Ctx) ->
    throw({wasm_error, #{class => Class, kind => Kind, msg => Msg, ctx => Ctx}}).

%%% ------------------------------------------------------------- boundary ---

-doc """
Run `Fun`, converting an internal throw into `{error, Error}`.

It also converts unexpected Erlang exceptions into a structured `internal` error
rather than letting them escape. A bug in this library still has to reach you as
a value, because the whole point of the runtime is that hostile input cannot
destabilise its caller.
""".
-spec capture(fun(() -> Result)) -> Result | {error, error()}.
capture(Fun) -> capture(Fun, #{}).

-spec capture(fun(() -> Result), map()) -> Result | {error, error()}.
capture(Fun, Ctx0) ->
    try Fun()
    catch
        throw:{wasm_error, Err} ->
            {error, add_context(Err, Ctx0)};
        %% A wasm exception in flight is not a failure of this call: it is
        %% unwinding towards a handler in an outer instance. Letting it through
        %% is what makes an imported function's `throw' catchable by its caller.
        throw:{wasm_exception, _} = E ->
            erlang:throw(E);
        Class:Reason:Stack ->
            {error, #{class => malformed,
                      kind  => internal,
                      msg   => <<"internal error">>,
                      ctx   => Ctx0#{exception => {Class, Reason},
                                     stacktrace => Stack}}}
    end.

-doc "Add fields to an error already caught, without losing what is there.".
-spec add_context(error(), map()) -> error().
add_context(#{ctx := Ctx} = Err, Extra) when map_size(Extra) =:= 0 ->
    Err#{ctx := Ctx};
add_context(#{ctx := Ctx} = Err, Extra) ->
    %% Existing context wins: it was recorded closer to the failure.
    Err#{ctx := maps:merge(Extra, Ctx)}.

-doc "Whether this term is one of this module's errors.".
-spec is_error(term()) -> boolean().
is_error(#{class := C, kind := _, msg := _, ctx := _}) ->
    lists:member(C, [malformed, invalid, link, trap, exhaustion]);
is_error(_) ->
    false.

-doc "Render an error on one line, for your logs and test failures.".
-spec format(error()) -> iolist().
format(#{class := Class, kind := Kind, msg := Msg, ctx := Ctx}) ->
    [atom_to_binary(Class), ": ", Msg,
     " (", atom_to_binary(Kind), ")", format_ctx(Ctx)].

format_ctx(Ctx) when map_size(Ctx) =:= 0 -> [];
format_ctx(Ctx) ->
    Interesting = maps:with([func, func_name, offset, path, expected, got,
                             index, limit], Ctx),
    case maps:size(Interesting) of
        0 -> [];
        _ -> [" ", io_lib:format("~0p", [Interesting])]
    end.

%%% ---------------------------------------------------------------- texts ---

%% Message text matches the specification test suite's expected strings so the
%% spec driver can assert on failure reason, not just on failure.
trap_msg(unreachable)                    -> <<"unreachable">>;
trap_msg(integer_divide_by_zero)         -> <<"integer divide by zero">>;
trap_msg(integer_overflow)               -> <<"integer overflow">>;
trap_msg(invalid_conversion_to_integer)  -> <<"invalid conversion to integer">>;
trap_msg(out_of_bounds_memory_access)    -> <<"out of bounds memory access">>;
trap_msg(out_of_bounds_table_access)     -> <<"out of bounds table access">>;
trap_msg(undefined_element)              -> <<"undefined element">>;
trap_msg(uninitialized_element)          -> <<"uninitialized element">>;
trap_msg(indirect_call_type_mismatch)    -> <<"indirect call type mismatch">>;
trap_msg({host_error, _})                -> <<"host error">>;
trap_msg(Other) when is_atom(Other)      -> atom_to_binary(Other);
trap_msg(_)                              -> <<"trap">>.

reason_kind({host_error, _}) -> host_error;
reason_kind(Atom) when is_atom(Atom) -> Atom;
reason_kind(_) -> trap.

exhaustion_msg(call_stack_exhausted) -> <<"call stack exhausted">>;
exhaustion_msg(out_of_fuel)          -> <<"out of fuel">>;
exhaustion_msg(memory_limit)         -> <<"memory limit exceeded">>;
exhaustion_msg(table_limit)          -> <<"table limit exceeded">>;
exhaustion_msg(host_call_limit)      -> <<"host call limit exceeded">>;
exhaustion_msg(Other)                -> atom_to_binary(Other).
