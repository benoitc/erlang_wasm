-module(relop).
-export([main/1]).

%% As written in wasm_exec: an atom_to_list per comparison, then a string match.
as_written(Op, A, B, W) ->
    case atom_to_list(Op) of
        [_, _, _, _ | "eq"] -> b(A =:= B);
        [_, _, _, _ | "ne"] -> b(A =/= B);
        [_, _, _, _ | "lt_s"] -> b(A < B);
        [_, _, _, _ | "gt_s"] -> b(A > B);
        [_, _, _, _ | "le_s"] -> b(A =< B);
        [_, _, _, _ | "ge_s"] -> b(A >= B);
        [_, _, _, _ | "lt_u"] -> b(u(A, W) < u(B, W));
        [_, _, _, _ | "gt_u"] -> b(u(A, W) > u(B, W));
        [_, _, _, _ | "le_u"] -> b(u(A, W) =< u(B, W));
        [_, _, _, _ | "ge_u"] -> b(u(A, W) >= u(B, W))
    end.

%% The same answers, matched on the atom itself.
direct(i32_eq, A, B) -> b(A =:= B);
direct(i32_ne, A, B) -> b(A =/= B);
direct(i32_lt_s, A, B) -> b(A < B);
direct(i32_gt_s, A, B) -> b(A > B);
direct(i32_le_s, A, B) -> b(A =< B);
direct(i32_ge_s, A, B) -> b(A >= B);
direct(i32_lt_u, A, B) -> b(u(A, 32) < u(B, 32));
direct(i32_gt_u, A, B) -> b(u(A, 32) > u(B, 32));
direct(i32_le_u, A, B) -> b(u(A, 32) =< u(B, 32));
direct(i32_ge_u, A, B) -> b(u(A, 32) >= u(B, 32)).

b(true) -> 1;
b(false) -> 0.
u(V, 32) -> wasm_num:to_u32(V);
u(V, 64) -> wasm_num:to_u64(V).

main(_) ->
    N = 2000000,
    io:format("i32.ge_u as written   ~.2f ns~n",
              [min5(fun() -> loop_a(N, i32_ge_u) end) / N]),
    io:format("i32.ge_u direct clause ~.2f ns~n",
              [min5(fun() -> loop_b(N, i32_ge_u) end) / N]),
    io:format("i32.eq   as written   ~.2f ns~n",
              [min5(fun() -> loop_a(N, i32_eq) end) / N]),
    io:format("i32.eq   direct clause ~.2f ns~n",
              [min5(fun() -> loop_b(N, i32_eq) end) / N]),
    init:stop().

loop_a(0, _) -> ok;
loop_a(N, Op) -> _ = as_written(Op, N, 7, 32), loop_a(N - 1, Op).
loop_b(0, _) -> ok;
loop_b(N, Op) -> _ = direct(Op, N, 7), loop_b(N - 1, Op).

min5(F) -> lists:min([element(1, timer:tc(F)) * 1000 || _ <- lists:seq(1, 5)]).
