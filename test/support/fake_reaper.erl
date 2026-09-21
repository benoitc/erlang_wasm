%% @doc A controllable stand-in for `wasm_worker_reaper', for fault injection.
%%
%% It registers under the reaper's own name, so `wasm_worker_reaper:reserve/4',
%% `register/2', `withdraw/2' and `transfer/3' route to it: those are module
%% functions that call `gen_server:call(wasm_worker_reaper, ...)', and this
%% process answers to that name. `wasm_worker_reaper:alive/0' is `whereis' of
%% the same name, so a running fake reads as alive.
%%
%% Each operation has a mode set by the test: `ack' replies the ordinary
%% success value, `hang' never replies (the caller blocks, which is the wedge
%% the steward removes), and `{die, Reason}' stops the fake so the caller sees
%% a `noproc'. `attempts/1' counts how many times an operation was reached, so
%% a test asserts the wedge was actually exercised rather than skipped.
%%
%% Suspend the supervised reaper with `wasm_worker_sup:suspend_reaper/0' before
%% starting one of these, or the name is taken.
-module(fake_reaper).
-behaviour(gen_server).

-export([start_link/1, stop/0, set_mode/2, attempts/1, waiting/1, release/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(SERVER, wasm_worker_reaper).

-type op() :: reserve | register | withdraw | transfer.
-type mode() :: ack | hang | {die, term()}.

-record(s, {dir :: file:filename_all(),
            roots :: [atom()],
            token = 0 :: non_neg_integer(),
            modes = #{} :: #{op() => mode()},
            attempts = #{} :: #{op() => non_neg_integer()},
            %% Callers parked by a `hang' mode, per operation, with the success
            %% value each would have received, so a test can both prove they are
            %% parked and later let them go with the ordinary reply.
            parked = #{} :: #{op() => [{gen_server:from(), term()}]}}).

%% `dir' is where `reserve' answers point; `roots' is what `roots' answers, so
%% `wasm_script_worker:start_link/2' accepts the worker's root.
-spec start_link(#{dir := file:filename_all(), roots => [atom()]}) ->
          {ok, pid()}.
start_link(Opts) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, Opts, []).

-spec stop() -> ok.
stop() ->
    case whereis(?SERVER) of
        undefined -> ok;
        _         -> gen_server:stop(?SERVER)
    end.

-spec set_mode(op(), mode()) -> ok.
set_mode(Op, Mode) -> gen_server:call(?SERVER, {set_mode, Op, Mode}).

-spec attempts(op()) -> non_neg_integer().
attempts(Op) -> gen_server:call(?SERVER, {attempts, Op}).

-spec waiting(op()) -> non_neg_integer().
waiting(Op) -> gen_server:call(?SERVER, {waiting, Op}).

%% Reply `ok' to everything parked on `Op', so a hung caller unblocks.
-spec release(op()) -> ok.
release(Op) -> gen_server:call(?SERVER, {release, Op}).

init(Opts) ->
    {ok, #s{dir = maps:get(dir, Opts),
            roots = maps:get(roots, Opts, [scratch])}}.

handle_call({set_mode, Op, Mode}, _From, S) ->
    {reply, ok, S#s{modes = maps:put(Op, Mode, S#s.modes)}};
handle_call({attempts, Op}, _From, S) ->
    {reply, maps:get(Op, S#s.attempts, 0), S};
handle_call({waiting, Op}, _From, S) ->
    {reply, length(maps:get(Op, S#s.parked, [])), S};
handle_call({release, Op}, _From, S) ->
    [gen_server:reply(F, Ok) || {F, Ok} <- maps:get(Op, S#s.parked, [])],
    {reply, ok, S#s{parked = maps:remove(Op, S#s.parked)}};
handle_call(roots, _From, S) ->
    {reply, S#s.roots, S};
handle_call({reserve, _Id, _Guardian, _Root, RelPath}, From, S0) ->
    S = count(reserve, S0),
    Dir = filename:join(S#s.dir, RelPath),
    act(reserve, From, {ok, Dir}, S);
handle_call({register, _Id, _Action}, From, S0) ->
    S = count(register, S0#s{token = S0#s.token + 1}),
    act(register, From, {ok, S#s.token}, S);
handle_call({withdraw, _Id, _Token}, From, S0) ->
    S = count(withdraw, S0),
    act(withdraw, From, ok, S);
handle_call({transfer, _Id, _Mod, _AState}, From, S0) ->
    S = count(transfer, S0),
    act(transfer, From, ok, S);
handle_call(_Msg, _From, S) ->
    {reply, ok, S}.

handle_cast(_Msg, S) -> {noreply, S}.

handle_info(_Msg, S) -> {noreply, S}.

%%% ---------------------------------------------------------------- internal ---

count(Op, S) ->
    S#s{attempts = maps:update_with(Op, fun(N) -> N + 1 end, 1, S#s.attempts)}.

%% `ack' answers the success value; `hang' parks the caller and never answers;
%% `{die, Reason}' stops the fake, so the caller's `gen_server:call' exits.
act(Op, From, Ok, S) ->
    case maps:get(Op, S#s.modes, ack) of
        ack ->
            {reply, Ok, S};
        hang ->
            Parked = maps:update_with(Op, fun(L) -> [{From, Ok} | L] end,
                                      [{From, Ok}], S#s.parked),
            {noreply, S#s{parked = Parked}};
        {die, Reason} ->
            {stop, Reason, S}
    end.
