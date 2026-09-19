-module(wasm_worker_sup).
-moduledoc """
Internal: supervises the reaper, so a worker needs nobody to start one.

The reaper is the node-wide process that cleans up after a request whose
owner is gone. It is started one of two ways, both built by `reaper_spec/0`
so that the two can never disagree:

- **At boot, on configured roots.** With `scratch_roots` set in the `wasm`
  application environment, the reaper starts with the application. That is
  when a crashed node's leftover directories are found and cleaned, which is
  why production should set it. A configured root belongs to one node at a
  time: a reaper treats a journal record from another node's incarnation as
  orphaned and deletes what it names.
- **On first use, on a root of its own.** Without `scratch_roots`, the first
  `wasm_script_worker:start_link/2,3` starts it with one root, `scratch`, in a
  directory under the user cache named for this node and OS process, so no two
  live nodes share it. The reaper removes that directory at a clean shutdown
  when nothing is left in it. After a crash of the whole node it is not
  reclaimed.

`reaper_options` in the application environment is passed to the reaper as
its settings; a key it does not know refuses the start, naming the key.

`suspend_reaper/0` and `resume_reaper/0` exist for `wasm_adapter_conformance`,
whose cases stop and restart a reaper of their own by hand.
""".

-behaviour(supervisor).

-export([start_link/0, init/1]).
-export([ensure_reaper/0, suspend_reaper/0, resume_reaper/0, reaper_spec/0]).

-define(SUSPENDED, {?MODULE, suspended}).

-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    persistent_term:put(?SUSPENDED, false),
    Flags = #{strategy => one_for_one, intensity => 10, period => 60},
    case configured() of
        false ->
            {ok, {Flags, []}};
        true ->
            case check_options() of
                ok         -> {ok, {Flags, [reaper_spec()]}};
                {error, E} -> {stop, E}
            end
    end.

-doc """
Make sure a reaper is running, starting the supervised one if not.

Does nothing when a reaper is already running, including one started by hand,
when the reaper is suspended, or when the `wasm` application is not.
""".
-spec ensure_reaper() -> ok | {error, term()}.
ensure_reaper() ->
    case whereis(?MODULE) =/= undefined andalso
         not wasm_worker_reaper:alive() andalso
         not persistent_term:get(?SUSPENDED, false) of
        true  -> start_reaper();
        false -> ok
    end.

-doc """
Stop the supervised reaper and start no other until `resume_reaper/0`.

For a test that runs a reaper of its own, by hand. The supervised one is shut
down cleanly, so a root it generated is removed if it was idle.
""".
-spec suspend_reaper() -> ok.
suspend_reaper() ->
    persistent_term:put(?SUSPENDED, true),
    _ = supervisor:terminate_child(?MODULE, wasm_worker_reaper),
    _ = supervisor:delete_child(?MODULE, wasm_worker_reaper),
    ok.

-doc """
Undo `suspend_reaper/0`. With `scratch_roots` configured the reaper starts at
once, so recovery on those roots does not wait for the next worker.
""".
-spec resume_reaper() -> ok | {error, term()}.
resume_reaper() ->
    persistent_term:put(?SUSPENDED, false),
    case configured() of
        true  -> ensure_reaper();
        false -> ok
    end.

-doc """
The reaper's child spec: configured roots when `scratch_roots` is set, a
generated root of this node's own otherwise. The only place either is built.
""".
-spec reaper_spec() -> supervisor:child_spec().
reaper_spec() ->
    {Roots, Generated} =
        case configured() of
            true  -> {application:get_env(wasm, scratch_roots, #{}), []};
            false -> {#{scratch => fallback_dir()}, [scratch]}
        end,
    #{id => wasm_worker_reaper,
      start => {wasm_worker_reaper, start_link,
                [Roots, application:get_env(wasm, reaper_options, #{}),
                 #{generated => Generated}]},
      restart => permanent,
      shutdown => 10000,
      type => worker,
      modules => [wasm_worker_reaper]}.

%%% ------------------------------------------------------------ internal ---

start_reaper() ->
    case check_options() of
        {error, _} = E ->
            E;
        ok ->
            case supervisor:start_child(?MODULE, reaper_spec()) of
                {ok, _}                       -> ok;
                {error, {already_started, _}} -> ok;
                {error, already_present}      ->
                    case supervisor:restart_child(?MODULE, wasm_worker_reaper) of
                        {ok, _}                         -> ok;
                        {error, running}                -> ok;
                        {error, {already_started, _}}   -> ok;
                        {error, _} = E                  -> E
                    end;
                {error, _} = E ->
                    E
            end
    end.

configured() ->
    case application:get_env(wasm, scratch_roots) of
        {ok, Roots} when is_map(Roots), map_size(Roots) > 0 -> true;
        _                                                   -> false
    end.

check_options() ->
    case application:get_env(wasm, reaper_options, #{}) of
        Opts when is_map(Opts) ->
            case maps:keys(Opts) -- wasm_worker_reaper:setting_keys() of
                []      -> ok;
                Unknown -> {error, {unknown_reaper_option, Unknown}}
            end;
        Other ->
            {error, {bad_reaper_options, Other}}
    end.

%% Named for this node and this OS process, and made unique within them, so no
%% two live nodes can share it and one node's recovery never deletes another's
%% directories.
fallback_dir() ->
    Name = lists:flatten(io_lib:format("~s-~s-~w",
                                       [node(), os:getpid(),
                                        erlang:unique_integer([positive])])),
    filename:join(filename:basedir(user_cache, "erlang_wasm/scratch"), Name).
