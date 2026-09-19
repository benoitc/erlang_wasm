%% @doc `fake_reactor_adapter', recording the request `prepare/3' is handed.
%%
%% For the cases that check what `wasm_script_worker:run/3' and `submit/3'
%% build: the kernel never reads inside a request, so the only place to see
%% one is the adapter it reaches.
-module(fake_recording_adapter).
-behaviour(wasm_worker_adapter).

-export([artifact/1, requirements/2, prepare/3, decode/2, cleanup/1,
         capabilities/1, conformance_fixtures/1, classify/2]).
-export([last_request/0, forget/0]).

-define(KEY, {?MODULE, last_request}).

last_request() -> persistent_term:get(?KEY, none).
forget()       -> persistent_term:erase(?KEY), ok.

%% The source names the export to call, so a request built by the wrappers can
%% be the echo (`handle') or the runaway (`spin').
prepare(Request, Artifact, Env) ->
    persistent_term:put(?KEY, Request),
    Call = case Request of
               #{source := S} -> #{call => S};
               _              -> #{}
           end,
    fake_reactor_adapter:prepare(maps:merge(Request, Call), Artifact, Env).

artifact(Opts)                -> fake_reactor_adapter:artifact(Opts).
requirements(Request, A)      -> fake_reactor_adapter:requirements(Request, A).
decode(Result, State)         -> fake_reactor_adapter:decode(Result, State).
cleanup(State)                -> fake_reactor_adapter:cleanup(State).
capabilities(A)               -> (fake_reactor_adapter:capabilities(A))#{
                                     snapshots => unsupported}.
conformance_fixtures(A)       -> fake_reactor_adapter:conformance_fixtures(A).
classify(Result, State)       -> fake_reactor_adapter:classify(Result, State).
