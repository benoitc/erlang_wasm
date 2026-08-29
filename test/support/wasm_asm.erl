%% @doc A minimal assembler for hand-built test modules.
%%
%% The specification fixtures are generated rather than committed, so a fresh
%% clone skips them. Suites that need to pin a rule independently of the
%% fixtures build their modules here instead: no toolchain dependency, and each
%% byte is visible next to the rule it exercises.
%%
%% Deliberately not a general assembler. It covers the section shapes the unit
%% suites use and nothing else, so instruction bodies are written as literal
%% bytes at the call site where the opcodes are the point.
-module(wasm_asm).

-export([module/1, section/2]).
-export([type_section/1, import_section/1, func_section/1, memory_section/3,
         table_section/1, global_section/1, export_section/1, code_section/1,
         data_section/1, data_count_section/1, elem_section/1]).
-export([limits/3, name/1, vec/1, uleb/1, sleb/1]).

-define(I32, 16#7F).
-define(I64, 16#7E).
-define(F32, 16#7D).
-define(F64, 16#7C).
-define(V128, 16#7B).
-define(FUNCREF, 16#70).

%%% ---------------------------------------------------------------- module ---

-spec module([iodata()]) -> binary().
module(Sections) ->
    iolist_to_binary([<<"\0asm", 1:32/little>> | Sections]).

-spec section(byte(), iodata()) -> iodata().
section(Id, Payload) ->
    Bin = iolist_to_binary(Payload),
    [Id, uleb(byte_size(Bin)), Bin].

%%% -------------------------------------------------------------- sections ---

%% Types are given as `{Params, Results}' with value types as bytes.
type_section(Types) ->
    section(1, [uleb(length(Types)) |
                [[16#60, vec([<<T>> || T <- P]), vec([<<T>> || T <- R])]
                 || {P, R} <- Types]]).

%% Only memory imports, which is all the suites need so far.
import_section(Imports) ->
    section(2, [uleb(length(Imports)) |
                [[name(M), name(N), 16#02, limits(Flags, Min, undefined)]
                 || {M, N, Flags, Min} <- Imports]]).

func_section(Types) -> section(3, vec([uleb(T) || T <- Types])).

table_section(Tables) ->
    section(4, [uleb(length(Tables)) |
                [[ET, limits(16#01, Min, Max)] || {ET, Min, Max} <- Tables]]).

memory_section(Flags, Min, Max) ->
    section(5, [uleb(1), limits(Flags, Min, Max)]).

%% Globals are `{ValType, Mutable, InitBytes}'.
global_section(Globals) ->
    section(6, [uleb(length(Globals)) |
                [[T, case Mut of true -> 1; false -> 0 end, Init, 16#0B]
                 || {T, Mut, Init} <- Globals]]).

export_section(Exports) ->
    section(7, [uleb(length(Exports)) |
                [[name(N), Kind, uleb(Idx)] || {N, Kind, Idx} <- Exports]]).

%% Active element segments into table 0 at a constant offset.
elem_section(Segments) ->
    section(9, [uleb(length(Segments)) |
                [[0, <<16#41>>, sleb(Off), 16#0B, vec([uleb(F) || F <- Funcs])]
                 || {Off, Funcs} <- Segments]]).

%% Bodies are raw instruction bytes; the locals declaration is always empty,
%% since a suite that needs locals declares them as parameters instead.
code_section(Bodies) ->
    section(10, [uleb(length(Bodies)) |
                 [[uleb(byte_size(B) + 1), 0, B] || B <- Bodies]]).

%% Passive segments only: mode 1, then the bytes.
data_section(Segments) ->
    section(11, [uleb(length(Segments)) |
                 [[1, uleb(byte_size(S)), S] || S <- Segments]]).

data_count_section(N) -> section(12, uleb(N)).

%%% ---------------------------------------------------------------- pieces ---

limits(Flags, Min, undefined) -> [Flags, uleb(Min)];
limits(Flags, Min, Max) -> [Flags, uleb(Min), uleb(Max)].

name(N) -> [uleb(byte_size(N)), N].

vec(Items) -> [uleb(length(Items)) | Items].

uleb(N) when N < 128 -> <<N>>;
uleb(N) -> <<1:1, (N band 16#7F):7, (uleb(N bsr 7))/binary>>.

%% Signed LEB128, for the constant expressions in segment offsets.
sleb(N) when N >= -64, N < 64 -> <<(N band 16#7F)>>;
sleb(N) ->
    <<1:1, (N band 16#7F):7, (sleb(N bsr 7))/binary>>.
