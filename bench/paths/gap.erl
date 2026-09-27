-module(gap).
-moduledoc """
What compiled wasm costs against the same algorithm written in Erlang.

Use it before claiming that a change brings the compiled tier closer to plain
Erlang, and to find which class of code is furthest from it. Each kernel exists
three times: hand-written Erlang (the floor), the interpreter, and the compiled
tier forced on.

    erlc -o bench/paths -pa _build/default/lib/wasm/ebin \\
        bench/paths/allocwords.erl bench/paths/gap.erl
    erl -noshell -pa _build/default/lib/wasm/ebin -pa bench/paths \\
        -run gap main sieve compiled

Kernels: `loop`, `fib`, `sieve`, `rmw`, `mandel`, `fnv`, `xorshift`,
`indirect`, `brtable`, and `null`, which runs the same Erlang under the arm
names `native` and `native_b` to show what the box does to two identical arms.

Arms: `native` (and `native_array`, `native_bin` where a kernel has them),
`interp`, `compiled`, `alloc_<arm>` for heap words per unit, and `dump`, which
writes the kernel's Core Erlang to `core.txt` and its BEAM assembly to
`wasm.S` so the instructions the compiled tier pays can be read against
`erlc -S` of the Erlang arm.

The Erlang memory arms keep one byte per `atomics` slot, an idealised layout
that isolates the engine's cost from the representation's: `native_array` and
`native_bin` are the layouts an Erlang programmer would reach for, and both
are slower than the compiled kernel.

One kernel and arm per VM, several launches, interleaved, minimum of five
runs each: see `README.md`. The compiled arm asserts that every timed call
entered generated code.
""".
-export([main/1]).

-define(M32, 16#FFFFFFFF).
-define(M64, 16#FFFFFFFFFFFFFFFF).
-define(OPTS, #{compile => true, compile_after => 1, compile_force => true,
                compile_sync => true, fuel => infinity}).

main([Kernel, Arm]) ->
    {ok, _} = application:ensure_all_started(wasm),
    {Wat, Name, Args, Units, Natives} = kernel(list_to_atom(Kernel)),
    Load = string:trim(os:cmd("uptime | sed 's/.*averages*: //'")),
    R = case Arm of
            "dump" -> dump(Wat);
            "alloc_" ++ Sub -> alloc(Sub, Wat, Name, Args, Units, Natives);
            _ -> time(Arm, Wat, Name, Args, Units, Natives)
        end,
    io:format("~s\t~s\t~s\tload=~s~n", [Kernel, Arm, R, Load]),
    halt().

%%% ---------------------------------------------------------------- kernels ---
%%
%% `{Wat, Export, Args, Units, Natives}': `Units' maps the result to the count
%% the time is divided by, and `Natives' holds the Erlang arms.

kernel(loop) ->
    {~"(module
  (func (export \"bench\") (param $n i32) (result i32)
    (local $i i32) (local $acc i32)
    (block $done
      (loop $l
        (br_if $done (i32.ge_u (local.get $i) (local.get $n)))
        (local.set $acc (i32.add (local.get $acc)
                                 (i32.mul (local.get $i) (i32.const 3))))
        (local.set $acc (i32.xor (local.get $acc)
                                 (i32.shr_u (local.get $acc) (i32.const 7))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $l)))
    (local.get $acc)))",
     ~"bench", [4000000], fun(_) -> 4000000 end,
     #{native => fun() -> n_loop(0, 4000000, 0) end}};
kernel(fib) ->
    %% Timed per call: fib(27) makes 2 * fib(28) - 1 calls.
    {~"(module
  (func $fib (export \"fib\") (param $n i32) (result i32)
    (if (result i32) (i32.lt_u (local.get $n) (i32.const 2))
      (then (local.get $n))
      (else (i32.add (call $fib (i32.sub (local.get $n) (i32.const 1)))
                     (call $fib (i32.sub (local.get $n) (i32.const 2))))))))",
     ~"fib", [27], fun(_) -> 2 * 317811 - 1 end,
     #{native => fun() -> fib(27) end}};
kernel(sieve) ->
    {~"(module (memory 16)
  (func (export \"sieve\") (param $n i32) (result i32)
    (local $i i32) (local $j i32) (local $c i32)
    (block $d0 (loop $l0
      (br_if $d0 (i32.ge_u (local.get $i) (local.get $n)))
      (i32.store8 (local.get $i) (i32.const 0))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $l0)))
    (local.set $i (i32.const 2))
    (block $d1 (loop $l1
      (br_if $d1 (i32.ge_u (local.get $i) (local.get $n)))
      (if (i32.eqz (i32.load8_u (local.get $i)))
        (then
          (local.set $c (i32.add (local.get $c) (i32.const 1)))
          (if (i32.le_u (local.get $i) (i32.const 65535))
            (then
              (local.set $j (i32.mul (local.get $i) (local.get $i)))
              (block $d2 (loop $l2
                (br_if $d2 (i32.ge_u (local.get $j) (local.get $n)))
                (i32.store8 (local.get $j) (i32.const 1))
                (local.set $j (i32.add (local.get $j) (local.get $i)))
                (br $l2)))))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $l1)))
    (local.get $c)))",
     ~"sieve", [1000000], fun(_) -> 1000000 end,
     #{native => fun() -> sieve_at(1000000) end,
       native_array => fun() -> sieve_arr(1000000) end}};
kernel(rmw) ->
    %% A read-modify-write of every byte of a 64 KiB window, 32 laps. Every
    %% byte becomes non-zero, so every packed word the engine reads is past
    %% the small-integer range: this is the bignum-word kernel.
    {~"(module (memory 1)
  (func (export \"rmw\") (param $n i32) (result i32)
    (local $i i32) (local $a i32) (local $v i32)
    (block $d (loop $l
      (br_if $d (i32.ge_u (local.get $i) (local.get $n)))
      (local.set $v (i32.load8_u (i32.and (local.get $i) (i32.const 65535))))
      (i32.store8 (i32.and (local.get $i) (i32.const 65535))
                  (i32.add (local.get $v) (i32.const 1)))
      (local.set $a (i32.add (local.get $a) (local.get $v)))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $l)))
    (local.get $a)))",
     ~"rmw", [65536 * 32], fun(_) -> 65536 * 32 end,
     #{native => fun() -> rmw_at(65536 * 32) end,
       native_bin => fun() -> rmw_bin(32) end}};
kernel(mandel) ->
    %% Timed per image, 200x200 at 64 iterations; divide by the result for a
    %% per-iteration figure.
    {~"(module
  (func (export \"mandel\") (param $w i32) (param $h i32) (param $max i32)
                            (result i32)
    (local $x i32) (local $y i32) (local $k i32) (local $tot i32)
    (local $cr f64) (local $ci f64) (local $zr f64) (local $zi f64)
    (local $t f64)
    (block $yd (loop $yl
      (br_if $yd (i32.ge_u (local.get $y) (local.get $h)))
      (local.set $ci
        (f64.sub (f64.div (f64.mul (f64.convert_i32_u (local.get $y))
                                   (f64.const 2.0))
                          (f64.convert_i32_u (local.get $h)))
                 (f64.const 1.0)))
      (local.set $x (i32.const 0))
      (block $xd (loop $xl
        (br_if $xd (i32.ge_u (local.get $x) (local.get $w)))
        (local.set $cr
          (f64.sub (f64.div (f64.mul (f64.convert_i32_u (local.get $x))
                                     (f64.const 3.0))
                            (f64.convert_i32_u (local.get $w)))
                   (f64.const 2.0)))
        (local.set $zr (f64.const 0)) (local.set $zi (f64.const 0))
        (local.set $k (i32.const 0))
        (block $kd (loop $kl
          (br_if $kd (i32.ge_u (local.get $k) (local.get $max)))
          (br_if $kd (f64.gt (f64.add (f64.mul (local.get $zr) (local.get $zr))
                                      (f64.mul (local.get $zi) (local.get $zi)))
                             (f64.const 4.0)))
          (local.set $t
            (f64.add (f64.sub (f64.mul (local.get $zr) (local.get $zr))
                              (f64.mul (local.get $zi) (local.get $zi)))
                     (local.get $cr)))
          (local.set $zi
            (f64.add (f64.mul (f64.mul (f64.const 2.0) (local.get $zr))
                              (local.get $zi))
                     (local.get $ci)))
          (local.set $zr (local.get $t))
          (local.set $k (i32.add (local.get $k) (i32.const 1)))
          (br $kl)))
        (local.set $tot (i32.add (local.get $tot) (local.get $k)))
        (local.set $x (i32.add (local.get $x) (i32.const 1)))
        (br $xl)))
      (local.set $y (i32.add (local.get $y) (i32.const 1)))
      (br $yl)))
    (local.get $tot)))",
     ~"mandel", [200, 200, 64], fun(R) -> R band ?M32 end,
     #{native => fun() -> mandel(200, 200, 64) end}};
kernel(fnv) ->
    {~"(module
  (func (export \"fnv\") (param $n i32) (result i64)
    (local $i i32) (local $h i64)
    (local.set $h (i64.const 0xcbf29ce484222325))
    (block $d (loop $l
      (br_if $d (i32.ge_u (local.get $i) (local.get $n)))
      (local.set $h
        (i64.mul (i64.xor (local.get $h)
                          (i64.extend_i32_u (i32.and (local.get $i)
                                                     (i32.const 255))))
                 (i64.const 0x100000001b3)))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $l)))
    (local.get $h)))",
     ~"fnv", [1000000], fun(_) -> 1000000 end,
     #{native => fun() -> fnv(1000000) end}};
kernel(xorshift) ->
    {~"(module
  (func (export \"xs\") (param $n i32) (result i64)
    (local $i i32) (local $x i64)
    (local.set $x (i64.const 88172645463325252))
    (block $d (loop $l
      (br_if $d (i32.ge_u (local.get $i) (local.get $n)))
      (local.set $x (i64.xor (local.get $x)
                             (i64.shl (local.get $x) (i64.const 13))))
      (local.set $x (i64.xor (local.get $x)
                             (i64.shr_u (local.get $x) (i64.const 7))))
      (local.set $x (i64.xor (local.get $x)
                             (i64.shl (local.get $x) (i64.const 17))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $l)))
    (local.get $x)))",
     ~"xs", [1000000], fun(_) -> 1000000 end,
     #{native => fun() -> xs(1000000) end}};
kernel(indirect) ->
    {~"(module
  (type $t (func (param i32) (result i32)))
  (table 4 funcref)
  (elem (i32.const 0) $f0 $f1 $f2 $f3)
  (func $f0 (type $t) (i32.add (local.get 0) (i32.const 1)))
  (func $f1 (type $t) (i32.mul (local.get 0) (i32.const 3)))
  (func $f2 (type $t) (i32.xor (local.get 0) (i32.const 0x5555)))
  (func $f3 (type $t) (i32.shr_u (local.get 0) (i32.const 1)))
  (func (export \"ind\") (param $n i32) (result i32)
    (local $i i32) (local $a i32)
    (block $d (loop $l
      (br_if $d (i32.ge_u (local.get $i) (local.get $n)))
      (local.set $a (call_indirect (type $t) (local.get $a)
                                   (i32.and (local.get $i) (i32.const 3))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $l)))
    (local.get $a)))",
     ~"ind", [1000000], fun(_) -> 1000000 end,
     #{native => fun() -> ind(1000000) end}};
kernel(brtable) ->
    {~"(module
  (func (export \"brt\") (param $n i32) (result i32)
    (local $i i32) (local $a i32)
    (block $d (loop $l
      (br_if $d (i32.ge_u (local.get $i) (local.get $n)))
      (block $next
        (block $c3 (block $c2 (block $c1 (block $c0
          (br_table $c0 $c1 $c2 $c3 (i32.and (local.get $i) (i32.const 3))))
          (local.set $a (i32.add (local.get $a) (i32.const 1))) (br $next))
         (local.set $a (i32.mul (local.get $a) (i32.const 3))) (br $next))
        (local.set $a (i32.xor (local.get $a) (i32.const 0x5555))) (br $next))
       (local.set $a (i32.shr_u (local.get $a) (i32.const 1))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $l)))
    (local.get $a)))",
     ~"brt", [1000000], fun(_) -> 1000000 end,
     #{native => fun() -> brt(1000000) end}};
kernel(null) ->
    {<<>>, <<>>, [], fun(_) -> 4000000 end,
     #{native => fun() -> n_loop(0, 4000000, 0) end,
       native_b => fun() -> n_loop(0, 4000000, 0) end}}.

%%% ------------------------------------------------------ the Erlang arms ---

n_loop(I, N, Acc) when I >= N -> Acc;
n_loop(I, N, Acc0) ->
    Acc1 = (Acc0 + I * 3) band ?M32,
    n_loop(I + 1, N, Acc1 bxor (Acc1 bsr 7)).

fib(N) when N < 2 -> N;
fib(N) -> fib(N - 1) + fib(N - 2).

%% One byte per slot, index = byte + 1, zeroed by `atomics:new/2'.
sieve_at(N) -> sieve_at(atomics:new(N, [{signed, false}]), 2, N, 0).

sieve_at(_A, I, N, C) when I >= N -> C;
sieve_at(A, I, N, C) ->
    case atomics:get(A, I + 1) of
        0 when I =< 65535 ->
            mark_at(A, I * I, I, N),
            sieve_at(A, I + 1, N, C + 1);
        0 -> sieve_at(A, I + 1, N, C + 1);
        _ -> sieve_at(A, I + 1, N, C)
    end.

mark_at(_A, J, _I, N) when J >= N -> ok;
mark_at(A, J, I, N) -> atomics:put(A, J + 1, 1), mark_at(A, J + I, I, N).

sieve_arr(N) -> sieve_arr(array:new(N, {default, 0}), 2, N, 0).

sieve_arr(_A, I, N, C) when I >= N -> C;
sieve_arr(A, I, N, C) ->
    case array:get(I, A) of
        0 when I =< 65535 ->
            sieve_arr(mark_arr(A, I * I, I, N), I + 1, N, C + 1);
        0 -> sieve_arr(A, I + 1, N, C + 1);
        _ -> sieve_arr(A, I + 1, N, C)
    end.

mark_arr(A, J, _I, N) when J >= N -> A;
mark_arr(A, J, I, N) -> mark_arr(array:set(J, 1, A), J + I, I, N).

rmw_at(N) -> rmw_at(atomics:new(65536, [{signed, false}]), 0, N, 0).

rmw_at(_A, I, N, S) when I >= N -> S;
rmw_at(A, I, N, S) ->
    Ix = (I band 65535) + 1,
    V = atomics:get(A, Ix),
    atomics:put(A, Ix, (V + 1) band 255),
    rmw_at(A, I + 1, N, (S + V) band ?M32).

%% What an Erlang programmer would write: a binary, rebuilt each lap.
rmw_bin(Laps) -> rmw_bin(binary:copy(<<0>>, 65536), Laps, 0).

rmw_bin(_B, 0, S) -> S;
rmw_bin(B, L, S) ->
    {B1, S1} = lap(B, <<>>, S),
    rmw_bin(B1, L - 1, S1).

lap(<<V, R/binary>>, Acc, S) ->
    lap(R, <<Acc/binary, ((V + 1) band 255)>>, (S + V) band ?M32);
lap(<<>>, Acc, S) -> {Acc, S}.

mandel(W, H, Max) -> my(0, W, H, Max, 0).

my(Y, _W, H, _Max, T) when Y >= H -> T;
my(Y, W, H, Max, T) ->
    Ci = Y * 2.0 / H - 1.0,
    my(Y + 1, W, H, Max, mx(0, W, Ci, Max, T)).

mx(X, W, _Ci, _Max, T) when X >= W -> T;
mx(X, W, Ci, Max, T) ->
    Cr = X * 3.0 / W - 2.0,
    mx(X + 1, W, Ci, Max, (T + mk(0, Max, 0.0, 0.0, Cr, Ci)) band ?M32).

mk(K, Max, _, _, _, _) when K >= Max -> K;
mk(K, Max, Zr, Zi, Cr, Ci) ->
    case Zr * Zr + Zi * Zi > 4.0 of
        true -> K;
        false -> mk(K + 1, Max, Zr * Zr - Zi * Zi + Cr, 2.0 * Zr * Zi + Ci,
                    Cr, Ci)
    end.

fnv(N) -> fnv(0, N, 16#cbf29ce484222325).

fnv(I, N, H) when I >= N -> H;
fnv(I, N, H) ->
    fnv(I + 1, N, ((H bxor (I band 255)) * 16#100000001b3) band ?M64).

xs(N) -> xs(0, N, 88172645463325252).

xs(I, N, X) when I >= N -> X;
xs(I, N, X0) ->
    X1 = X0 bxor ((X0 bsl 13) band ?M64),
    X2 = X1 bxor (X1 bsr 7),
    xs(I + 1, N, X2 bxor ((X2 bsl 17) band ?M64)).

ind(N) ->
    ind(0, N, 0, {fun(X) -> (X + 1) band ?M32 end,
                  fun(X) -> (X * 3) band ?M32 end,
                  fun(X) -> X bxor 16#5555 end,
                  fun(X) -> X bsr 1 end}).

ind(I, N, A, _) when I >= N -> A;
ind(I, N, A, Fs) -> ind(I + 1, N, (element((I band 3) + 1, Fs))(A), Fs).

brt(N) -> brt(0, N, 0).

brt(I, N, A) when I >= N -> A;
brt(I, N, A) ->
    A1 = case I band 3 of
             0 -> (A + 1) band ?M32;
             1 -> (A * 3) band ?M32;
             2 -> A bxor 16#5555;
             3 -> A bsr 1
         end,
    brt(I + 1, N, A1).

%%% ---------------------------------------------------------------- harness ---

body("interp", Wat, Name, Args, _Natives) ->
    {ok, M} = wasm:compile({wat, Wat}),
    {ok, I} = wasm:instantiate(M, #{}),
    %% Lowers the bodies in this process before anything is timed.
    _ = wasm:call(I, Name, Args),
    fun() -> {ok, [V]} = wasm:call(I, Name, Args), V end;
body("compiled", Wat, Name, Args, _Natives) ->
    {ok, M} = wasm:compile({wat, Wat}),
    {ok, I} = wasm:instantiate(M, #{}, ?OPTS),
    ok = warm(I, Name, Args, 200),
    fun() ->
        E0 = maps:get(entered, wasm_jit:counts()),
        {ok, [V]} = wasm:call(I, Name, Args, ?OPTS),
        true = maps:get(entered, wasm_jit:counts()) > E0,
        V
    end;
body(Arm, _Wat, _Name, _Args, Natives) ->
    maps:get(list_to_atom(Arm), Natives).

warm(_I, _Name, _Args, 0) -> erlang:error(never_entered);
warm(I, Name, Args, K) ->
    E0 = maps:get(entered, wasm_jit:counts()),
    {ok, _} = wasm:call(I, Name, Args, ?OPTS),
    case maps:get(entered, wasm_jit:counts()) > E0 of
        true -> ok;
        false -> timer:sleep(20), warm(I, Name, Args, K - 1)
    end.

%% Set up, one untimed run, then five timed runs, all in one fresh process.
time(Arm, Wat, Name, Args, Units, Natives) ->
    {Us, V} = benchlib:in_process(
                fun() ->
                        F = body(Arm, Wat, Name, Args, Natives),
                        _ = F(),
                        Rs = [timer:tc(F) || _ <- lists:seq(1, 5)],
                        {lists:min([T || {T, _} <- Rs]), element(2, hd(Rs))}
                end),
    U = Units(V),
    io_lib:format("~.2f ns/unit\tmin_us=~p units=~p result=~p",
                  [Us * 1000 / U, Us, U, norm(V)]).

%% Heap words per unit, less an empty window's own.
alloc(Arm, Wat, Name, Args, Units, Natives) ->
    #{allocated := A0} = allocwords:measure(fun() -> ok end, fun(_) -> ok end,
                                            60000),
    #{allocated := A, result := V, collections := C} =
        allocwords:measure(fun() ->
                                   F = body(Arm, Wat, Name, Args, Natives),
                                   _ = F(),
                                   F
                           end,
                           fun(F) -> F() end, 1200000),
    U = Units(V),
    io_lib:format("~.2f words/unit\twords=~p gcs=~p",
                  [(A - A0) / U, A - A0, C]).

%% The wasm arms answer signed values and the Erlang arms unsigned ones.
norm(V) when is_integer(V), V < 0, V >= -16#80000000 -> V band ?M32;
norm(V) when is_integer(V), V < 0 -> V band ?M64;
norm(V) -> V.

dump(Wat) ->
    {ok, M} = wasm:compile({wat, Wat}),
    {ok, I} = wasm:instantiate(M, #{}, #{}),
    Core = iolist_to_binary(wasm_jit:dump(I)),
    ok = file:write_file("core.txt", Core),
    {ok, Toks, _} = core_scan:string(binary_to_list(Core)),
    {ok, Mod} = core_parse:parse(Toks),
    {ok, _, Asm} = compile:forms(Mod, [from_core, 'S', binary, return_errors]),
    {ok, Fd} = file:open("wasm.S", [write]),
    beam_listing:module(Fd, Asm),
    ok = file:close(Fd),
    "wrote core.txt and wasm.S".
