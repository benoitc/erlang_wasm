-module(gapref).
-moduledoc """
The plain-Erlang reference kernels, and the check that compiled code ran.

Use it when a benchmark compares compiled wasm with the same algorithm written
in Erlang, or must prove that a timed call really ran generated code. `gap.erl`
and `bench/cross/vs/vs.erl` both call it, so there is one copy of each kernel
and one definition of "entered".

The kernels have the exact semantics of the wasm they stand for, so they return
the same checksums:

- `loop/1` is `bench/cross/loop.wat`: an i32 counted loop.
- `fib32/1` is `fib.wat` with 32-bit wrapping, values held unsigned with one
  `band` per operation, which is how an Erlang programmer would write i32
  arithmetic.
- `fib/1` is the idiomatic Erlang `fib`, with no wrapping, which agrees with
  `fib32/1` while no value overflows.
""".
-export([loop/1, n_loop/3, fib/1, fib32/1, fibi/1, f64loop/1, signed32/1]).
-export([entered/0, assert_entered/1, warm/5]).

-define(M32, 16#FFFFFFFF).

%%% ---------------------------------------------------------------- kernels ---

-doc "`bench/cross/loop.wat`'s `bench(N)`, as the signed i32 it returns.".
-spec loop(non_neg_integer()) -> integer().
loop(N) -> signed32(n_loop(0, N, 0)).

-doc "The loop itself: `Acc` held unsigned, one `band` per wrapping step.".
-spec n_loop(non_neg_integer(), non_neg_integer(), non_neg_integer()) ->
          non_neg_integer().
n_loop(I, N, Acc) when I >= N -> Acc;
n_loop(I, N, Acc0) ->
    Acc1 = (Acc0 + I * 3) band ?M32,
    n_loop(I + 1, N, Acc1 bxor (Acc1 bsr 7)).

-doc "Idiomatic Erlang `fib`, no wrapping.".
-spec fib(non_neg_integer()) -> non_neg_integer().
fib(N) when N < 2 -> N;
fib(N) -> fib(N - 1) + fib(N - 2).

-doc "`fib.wat` with exact i32 semantics, as the signed i32 it returns.".
-spec fib32(non_neg_integer()) -> integer().
fib32(N) -> signed32(f32(N band ?M32)).

f32(N) when N < 2 -> N;
f32(N) -> (f32((N - 1) band ?M32) + f32((N - 2) band ?M32)) band ?M32.

-doc """
`fibi.wat`: `fib32/1` with every recursive call through a fun held in a
tuple, which is what a call through a table is in Erlang.
""".
-spec fibi(non_neg_integer()) -> integer().
fibi(N) -> signed32(fi(N band ?M32, {fun fi/2})).

fi(N, _T) when N < 2 -> N;
fi(N, T) ->
    F = element(1, T),
    (F((N - 1) band ?M32, T) + F((N - 2) band ?M32, T)) band ?M32.

-doc "`f64.wat`'s `bench(N)`: the same float operations in the same order.".
-spec f64loop(non_neg_integer()) -> integer().
f64loop(N) -> f64l(0, N, 1.0, 0).

f64l(I, N, _X, C) when I >= N -> signed32(C);
f64l(I, N, X0, C) ->
    X = X0 * 1.000001 + 0.5,
    case X > 1000.0 of
        true -> f64l(I + 1, N, X - 999.0, (C + 1) band ?M32);
        false -> f64l(I + 1, N, X, C)
    end.

-doc "An unsigned 32-bit value read as the signed i32 a wasm function returns.".
-spec signed32(non_neg_integer()) -> integer().
signed32(V) when V >= 16#80000000 -> V - 16#100000000;
signed32(V) -> V.

%%% --------------------------------------------- did compiled code run? ---

-doc "How many times generated code has been entered on this node.".
-spec entered() -> non_neg_integer().
entered() ->
    C = wasm_jit:counts(),
    maps:get(entered, C, 0) + maps:get(reentered, C, 0).

-doc """
Run `Fun` and fail unless generated code was entered while it ran.

A compiled arm that silently interprets measures the interpreter, which is how
an earlier version of the cross-runtime harness read 70 ns an iteration for an
arithmetic loop that compiles to 3.
""".
-spec assert_entered(fun(() -> T)) -> T.
assert_entered(Fun) ->
    E0 = entered(),
    R = Fun(),
    case entered() > E0 of
        true -> R;
        false -> erlang:error(not_entered)
    end.

-doc "Call until generated code is entered, at most `K` times, or fail.".
-spec warm(term(), binary(), [term()], non_neg_integer(), map()) -> ok.
warm(_I, _Name, _Args, 0, _Opts) -> erlang:error(never_entered);
warm(I, Name, Args, K, Opts) ->
    E0 = entered(),
    {ok, _} = wasm:call(I, Name, Args, Opts),
    case entered() > E0 of
        true -> ok;
        false -> timer:sleep(20), warm(I, Name, Args, K - 1, Opts)
    end.
