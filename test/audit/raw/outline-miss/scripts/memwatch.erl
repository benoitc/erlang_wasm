-module(memwatch).
%% Samples erlang:memory(total) every 100 ms and rewrites File with the peak
%% so far, so the value survives the halt that ends the bench.
-export([start/1]).
start([File]) ->
    spawn(fun() -> loop(File, 0) end), ok.
loop(File, Max) ->
    M = erlang:memory(total),
    Max1 = case M > Max of
               true -> ok = file:write_file(File, integer_to_list(M)), M;
               false -> Max
           end,
    receive after 100 -> loop(File, Max1) end.
