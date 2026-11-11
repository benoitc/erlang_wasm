-module(wasm_worker_images).
-moduledoc """
Internal: the images script workers share, one per adapter, options and store
key, node-wide.

You do not call this. `wasm_script_worker:start_link/2,3` asks it before it
loads or captures an image. A worker started with the same adapter and the
same options as a live one, whose artifact gives the same store key, takes a
hold on that worker's image instead of building its own. One image then serves
the whole pool, with no option to ask for it.

## How a start finds its image

| state of the key | `share/4` answers |
| --- | --- |
| a live image | that image, held by the caller |
| a worker building it | waits for that build, then the image |
| nothing | what the caller's own build answers, which every caller waiting on it then shares |

A build that fails, or a builder that dies, hands the build to the next
caller waiting, so a pool started at once captures once and a failed capture
is tried again by the next worker, as each worker would have tried it.

An image is freed with its last holder. This server holds none: it watches the
image's owner and forgets the image when that owner exits, so the next start
builds again. A wait is bounded by the caller's own deadline; past it, the
caller builds an image of its own.
""".

-behaviour(gen_server).

-export([start_link/0, share/4]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(SERVER, ?MODULE).

-type key() :: term().

%% A key is `{ready, Image, OwnerMonitor}' or
%% `{building, BuilderPid, BuilderMonitor, Waiters}'. The image only: each
%% worker restores it with its own capability, whose bindings are its own.
-record(s, {keys = #{} :: #{key() => tuple()},
            mons = #{} :: #{reference() => key()}}).

-spec start_link() -> gen_server:start_ret().
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-doc """
The image for `Key`, held by the caller: a live one, answered with the
caller's own `Cap`, or the one `Build()` makes.

`Build()` answers `{ok, Image, Cap}` with the image held by the caller, or an
error, which is answered as is. `Wait` bounds how long the caller waits for
another worker's build, in milliseconds. Without this server, `Build()` runs
and nothing is shared.
""".
-spec share(key(), term(),
            fun(() -> {ok, wasm:snapshot(), term()} | {error, term()}),
            timeout()) -> {ok, wasm:snapshot(), term()} | {error, term()}.
share(Key, Cap, Build, Wait) ->
    case whereis(?SERVER) of
        undefined -> Build();
        _Pid      -> share(Key, Cap, Build, Wait, 3)
    end.

%% A shared image can be freed between the answer and the hold; the next ask
%% finds it gone and builds. Three tries, then the caller's own build.
share(_Key, _Cap, Build, _Wait, 0) ->
    Build();
share(Key, Cap, Build, Wait, Tries) ->
    case ask({checkout, Key}, Wait) of
        {shared, Image} ->
            case wasm:acquire(Image) of
                ok         -> {ok, Image, Cap};
                {error, _} -> share(Key, Cap, Build, Wait, Tries - 1)
            end;
        build ->
            built(Key, Build());
        timeout ->
            Build()
    end.

built(Key, {ok, Image, _Cap} = Ok) ->
    gen_server:cast(?SERVER, {publish, Key, self(), Image}),
    Ok;
built(Key, Error) ->
    gen_server:cast(?SERVER, {abandon, Key, self()}),
    Error.

%% A caller that stops waiting is no longer waiting: if the build was handed
%% to it meanwhile, it is handed on.
ask(Request, Wait) ->
    try gen_server:call(?SERVER, Request, Wait)
    catch
        exit:{timeout, _} ->
            gen_server:cast(?SERVER, {gave_up, element(2, Request), self()}),
            timeout;
        exit:_ ->
            timeout
    end.

%%% --------------------------------------------------------------- server ---

init([]) ->
    {ok, #s{}}.

handle_call({checkout, Key}, {Pid, _} = From, #s{keys = Keys} = S) ->
    case maps:get(Key, Keys, none) of
        {ready, Image, _Mon} ->
            {reply, {shared, Image}, S};
        {building, B, Mon, Waiters} ->
            WMon = erlang:monitor(process, Pid),
            {noreply, S#s{keys = Keys#{Key => {building, B, Mon,
                                               Waiters ++ [{From, WMon}]}},
                          mons = (S#s.mons)#{WMon => {waiter, Key}}}};
        none ->
            {reply, build, building(Key, Pid, [], S)}
    end;
handle_call(_Other, _From, S) ->
    {reply, {error, unknown_call}, S}.

handle_cast({publish, Key, Pid, Image}, #s{keys = Keys} = S) ->
    case maps:get(Key, Keys, none) of
        {building, Pid, Mon, Waiters} ->
            S1 = forget_mon(Mon, S),
            case wasm_snapshot:owner(Image) of
                Owner when is_pid(Owner) ->
                    S2 = lists:foldl(fun({W, WMon}, Acc) ->
                                             gen_server:reply(W, {shared, Image}),
                                             forget_mon(WMon, Acc)
                                     end, S1, Waiters),
                    OMon = erlang:monitor(process, Owner),
                    {noreply,
                     S2#s{keys = (S2#s.keys)#{Key => {ready, Image, OMon}},
                          mons = (S2#s.mons)#{OMon => Key}}};
                undefined ->
                    {noreply, next_builder(Key, Waiters, S1)}
            end;
        _ ->
            {noreply, S}
    end;
handle_cast({abandon, Key, Pid}, S) ->
    {noreply, abandoned(Key, Pid, S)};
handle_cast({gave_up, Key, Pid}, S) ->
    {noreply, gone_from(Key, Pid, S)};
handle_cast(_Other, S) ->
    {noreply, S}.

%% A builder that died hands its build on, a waiter that died waits no more,
%% and an image whose owner exited is freed, so the key is forgotten.
handle_info({'DOWN', Mon, process, Pid, _}, #s{mons = Mons} = S) ->
    case maps:take(Mon, Mons) of
        {{waiter, Key}, Mons1} ->
            {noreply, gone_from(Key, Pid, S#s{mons = Mons1})};
        {Key, Mons1} ->
            S1 = S#s{mons = Mons1},
            case maps:get(Key, S1#s.keys, none) of
                {building, Pid, Mon, _Waiters} ->
                    {noreply, abandoned(Key, Pid, S1)};
                {ready, _Image, Mon} ->
                    {noreply, S1#s{keys = maps:remove(Key, S1#s.keys)}};
                _ ->
                    {noreply, S1}
            end;
        error ->
            {noreply, S}
    end;
handle_info(_Other, S) ->
    {noreply, S}.

building(Key, Pid, Waiters, #s{keys = Keys, mons = Mons} = S) ->
    Mon = erlang:monitor(process, Pid),
    S#s{keys = Keys#{Key => {building, Pid, Mon, Waiters}},
        mons = Mons#{Mon => Key}}.

%% `Pid' is no longer after `Key': as its builder, or as a waiter.
gone_from(Key, Pid, #s{keys = Keys} = S) ->
    case maps:get(Key, Keys, none) of
        {building, Pid, _Mon, _Waiters} ->
            abandoned(Key, Pid, S);
        {building, B, Mon, Waiters} ->
            {Out, Left} = lists:partition(fun({{P, _}, _}) -> P =:= Pid end,
                                          Waiters),
            S1 = lists:foldl(fun({_, WMon}, Acc) -> forget_mon(WMon, Acc) end,
                             S, Out),
            S1#s{keys = Keys#{Key => {building, B, Mon, Left}}};
        _ ->
            S
    end.

abandoned(Key, Pid, #s{keys = Keys} = S) ->
    case maps:get(Key, Keys, none) of
        {building, Pid, Mon, Waiters} ->
            next_builder(Key, Waiters, forget_mon(Mon, S));
        _ ->
            S
    end.

next_builder(Key, [], S) ->
    S#s{keys = maps:remove(Key, S#s.keys)};
next_builder(Key, [{{Pid, _} = From, WMon} | Waiters], S) ->
    gen_server:reply(From, build),
    building(Key, Pid, Waiters, forget_mon(WMon, S)).

forget_mon(Mon, #s{mons = Mons} = S) ->
    erlang:demonitor(Mon, [flush]),
    S#s{mons = maps:remove(Mon, Mons)}.
