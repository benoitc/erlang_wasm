#!/usr/bin/env escript
main([Dir]) ->
    P50 = fun(F) -> {ok, Ts} = file:consult(F),
                    [L] = [X || {load_snapshot, plain, X} <- Ts],
                    S = lists:sort(L), lists:nth((length(S)+1) div 2, S) end,
    Med = fun(L) -> S = lists:sort(L), N = length(S),
                    case N rem 2 of 1 -> lists:nth((N+1) div 2, S);
                                    0 -> (lists:nth(N div 2, S)+lists:nth(N div 2+1, S))/2 end end,
    R = [{Rd, P50(f(Dir,main,Rd)), P50(f(Dir,cand,Rd)), P50(f(Dir,null,Rd))} || Rd <- lists:seq(1,10)],
    [io:format("r~p main ~.2f cand ~.2f null ~.2f  c/m ~.3f n/m ~.3f~n",[Rd,M,C,N,C/M,N/M]) || {Rd,M,C,N} <- R],
    Ms=[M||{_,M,_,_}<-R], Cs=[C||{_,_,C,_}<-R], Ns=[N||{_,_,_,N}<-R],
    io:format("median of VMs: main ~.2f cand ~.2f null ~.2f  cand/main ~.3f null/main ~.3f~n",
              [Med(Ms),Med(Cs),Med(Ns),Med(Cs)/Med(Ms),Med(Ns)/Med(Ms)]),
    io:format("paired median: cand/main ~.3f null/main ~.3f~n",
              [Med([C/M||{_,M,C,_}<-R]), Med([N/M||{_,M,_,N}<-R])]),
    Odd=[X||X={Rd,_,_,_}<-R, Rd rem 2 =:= 1], Ev=[X||X={Rd,_,_,_}<-R, Rd rem 2 =:= 0],
    [io:format("~s ordering paired cand/main ~.3f null/main ~.3f~n",[Nm,Med([C/M||{_,M,C,_}<-S]),Med([N/M||{_,M,_,N}<-S])]) || {Nm,S} <- [{"main-first",Odd},{"null-first",Ev}]].
f(Dir,A,R) -> filename:join(Dir, atom_to_list(A)++"-r"++integer_to_list(R)++".terms").
