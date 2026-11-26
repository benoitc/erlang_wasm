-module(wasm_actor_registry).
-moduledoc """
Where a sender finds an actor's queue, and who forgets an actor that died.

You do not call this. `wasm_actor:send/2` reads the table to find the
destination's queue counter, its capacity and its message type, without a
message to the actor and without waiting for it. Each actor writes its own
row when it starts and deletes it when it stops.

An actor killed outright never runs its cleanup, so this process monitors
every actor and deletes the row of one that is gone. Without it, each killed
actor would leave a row behind for the life of the node.

The table belongs to `wasm_store`, like every long-lived table, so this
process restarting loses nothing. It then monitors every actor still in the
table again: one that died in between is answered by an immediate `DOWN`.
""".
-behaviour(gen_server).

-export([start_link/0, ensure_table/0, watch/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(TAB, wasm_actors).

-spec start_link() -> {ok, pid()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-doc """
Create the actor table if it is not there. `wasm_store` calls this, so the
table outlives this process.
""".
-spec ensure_table() -> ok.
ensure_table() ->
    case ets:whereis(?TAB) of
        undefined ->
            try ets:new(?TAB, [named_table, set, public,
                               {read_concurrency, true},
                               {write_concurrency, true}])
            catch error:badarg -> ok
            end,
            ok;
        _ -> ok
    end.

-doc "Delete `Pid`'s row when it exits, however it exits.".
-spec watch(pid()) -> ok.
watch(Pid) -> gen_server:cast(?MODULE, {watch, Pid}).

%% An actor writes its row before it asks to be watched, and a restarted
%% registry registers its name before this scan. So a request lost with the
%% old registry is for a row the scan finds.
init([]) ->
    Live = ets:select(?TAB, [{{'$1', '_', '_', '_'}, [], ['$1']}]),
    _ = [monitor(process, Pid) || Pid <- Live],
    {ok, #{}}.

handle_call(_Req, _From, State) -> {reply, {error, unknown_call}, State}.

handle_cast({watch, Pid}, State) ->
    _ = monitor(process, Pid),
    {noreply, State};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'DOWN', _Ref, process, Pid, _Why}, State) ->
    true = ets:delete(?TAB, Pid),
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.
