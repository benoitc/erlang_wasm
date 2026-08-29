-module(fuseoff).
-export([main/1]).
main([Path]) ->
    {ok, _} = application:ensure_all_started(wasm),
    {ok, Bin} = file:read_file(Path),
    {ok, M} = wasm:compile(Bin),
    N = 1000000,
    [begin
         {ok, I} = wasm:instantiate(M, #{}, #{fuse => Fuse}),
         T = lists:min([element(1, timer:tc(fun() -> wasm:call(I, ~"bench", [N]) end))
                        || _ <- lists:seq(1, 5)]),
         io:format("fuse => ~-5w  ~.1f ns/iter~n", [Fuse, T * 1000 / N]),
         ok = wasm:destroy(I)
     end || Fuse <- [false, true]],
    init:stop().
