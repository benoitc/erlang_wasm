-module(wasm_snapshot_file).
-moduledoc """
The on-disk form of an initialized runtime snapshot.

Encoding and decoding only: this module opens no file, resolves no module and
calls nothing that could reach the facade, so it stays outside the cycle
`wasm_architecture_SUITE` asserts on. What it takes and answers is a plain map
of an image's contents, which `wasm_snapshot` knows how to take apart and put
back together.

## Why not `term_to_binary/1`

For the reason the reaper's journal records: `binary_to_term/1` on a planted
file materialises atoms **before** any structural check can reject the record,
and the atom table is node-wide and never reclaimed. A snapshot lives in a
directory an embedder names, which is exactly where a planted file would go.

So the format is explicit, every field is validated on the way in, and an atom
is decoded through `binary_to_existing_atom/2`, which cannot create one.

## The shape

```text
"WASMIMG\\0" | u16 format | u32 image ABI | u32 payload length
sha256 of the payload, checked before a byte of it is used
payload: u8 codec | u32 uncompressed length | body
body: sections, each u8 tag, u32 length, contents
```

The digest covers the payload **as stored**, so a corrupt file is refused
before it is decompressed rather than after. The uncompressed length is checked
against a caller-supplied ceiling first, because `zlib:uncompress/1` on a
crafted three-megabyte stream is otherwise a multi-gigabyte allocation.

## What a reader must still not assume

A digest proves the bytes are the bytes that were written. It proves nothing
about **who** wrote them, and a snapshot is not code but guest state injected
into a live runtime, which is worse rather than better: a table slot holds a
function index, so a planted image is a call to a function the module never
exposed. `wasm_snapshot` checks every index against the module's own function
count on the way back in, and the directory is documented as being as trusted
as the release, in the same words `wasm_code_cache` uses.
""".

-export([encode/1, decode/2]).
-export([own_atoms/0]).
-export([format_version/0, image_abi/0]).

-define(MAGIC, "WASMIMG\0").
-define(MAGIC_SIZE, 8).
-define(FORMAT, 1).

%% Bumped by hand when the **value representation** or the set of parts
%% changes, exactly as `wasm_jit`'s `?ABI` is. Nothing derives it, and an image
%% written under a different one is a miss rather than an error.
-define(IMAGE_ABI, 1).

-define(CODEC_RAW, 0).
-define(CODEC_ZLIB, 1).

%% Below this an image is stored as it is: compressing a few hundred bytes
%% costs more than it saves and makes the file harder to look at.
-define(COMPRESS_ABOVE, 4096).

-define(S_HASH, 1).
-define(S_VERSION, 2).
-define(S_KEY, 3).
-define(S_SHAPE, 4).
-define(S_GLOBALS, 5).
-define(S_TABLES, 6).
-define(S_MEMS, 7).
-define(S_DROPPED, 8).
-define(S_HOOKS, 9).

-type parts() :: #{hash := binary(), version := binary(), key := term(),
                   shape := term(), globals := [term()], tables := [[term()]],
                   mems := [map()], dropped := {map(), map()},
                   hooks := map()}.
-export_type([parts/0]).

-doc "The format this build writes. An older one is a miss, never an error.".
-spec format_version() -> pos_integer().
format_version() -> ?FORMAT.

-doc "The value-representation version, bumped by hand.".
-spec image_abi() -> pos_integer().
image_abi() -> ?IMAGE_ABI.

-doc """
The atoms the runtime's own values are made of, listed so that loading this
module interns them.

`unterm/1` decodes a name through `binary_to_existing_atom/2`, which is right:
nothing in a file may mint an atom. But "existing" is a property of the
emulator at that moment, and Erlang loads modules lazily, so without this the
answer depends on whether some unrelated module carrying the same literal
happened to have been loaded first.

That is not hypothetical. A CPython image holds `funcref` in its tables, and on
a node that had only started the application `binary_to_existing_atom(
<<"funcref">>, utf8)` raised `badarg`: the image was refused, `lookup/2` turned
the refusal into a miss as it must, and the worker spent 104 seconds capturing
a snapshot it already had on disk. `test/audit/ATTEMPTS.md` has that run.

Every name here is a literal in this module's source, so it is in this module's
atom table and exists from the moment the module is loaded -- which is before
it can decode anything. The set is exactly what `wasm_snapshot`'s `admissible`
admits, and the guarantee it restores is only about *these* names: an atom a
hook kept is still subject to existing already, because that one really does
come from outside.
""".
-spec own_atoms() -> [atom()].
own_atoms() ->
    [funcref, null, i31, nan, infinity, neg_infinity].

%%% --------------------------------------------------------------- encode ---

-spec encode(parts()) -> binary().
encode(Parts) ->
    Body = body(Parts),
    {Codec, Stored} = compress(Body),
    Payload = <<Codec, (byte_size(Body)):32, Stored/binary>>,
    <<?MAGIC, ?FORMAT:16, ?IMAGE_ABI:32, (byte_size(Payload)):32,
      (crypto:hash(sha256, Payload))/binary, Payload/binary>>.

compress(Body) when byte_size(Body) > ?COMPRESS_ABOVE ->
    %% Level 1. A started CPython is 88.5% zero even after the runs are taken
    %% out of it, and the difference between levels is far smaller than the
    %% difference between compressing and not.
    {?CODEC_ZLIB, zlib:compress(Body)};
compress(Body) ->
    {?CODEC_RAW, Body}.

body(#{hash := Hash, version := Version, key := Key, shape := Shape,
       globals := Globals, tables := Tables, mems := Mems,
       dropped := Dropped, hooks := Hooks}) ->
    iolist_to_binary(
      [sect(?S_HASH, Hash),
       sect(?S_VERSION, Version),
       sect(?S_KEY, term(Key)),
       sect(?S_SHAPE, term(Shape)),
       sect(?S_GLOBALS, term(Globals)),
       sect(?S_TABLES, term(Tables)),
       sect(?S_MEMS, term([{maps:get(pages, M), maps:get(runs, M)}
                           || M <- Mems])),
       sect(?S_DROPPED, term(Dropped)),
       sect(?S_HOOKS, term(Hooks))]).

sect(Tag, Bin) -> [<<Tag, (byte_size(Bin)):32>>, Bin].

%% The value encoding. Every shape an image may hold and nothing else, which is
%% the same list `wasm_snapshot:admissible/2` enforces at capture: a value that
%% cannot be written here could not have been captured either.
term(I) when is_integer(I) -> <<0, (zigzag(I)):64>>;
term(F) when is_float(F)   -> <<1, F:64/float>>;
term(B) when is_binary(B)  -> <<2, (byte_size(B)):32, B/binary>>;
term(A) when is_atom(A)    -> N = atom_to_binary(A, utf8),
                              <<3, (byte_size(N)):16, N/binary>>;
term(L) when is_list(L)    -> <<4, (length(L)):32,
                                (iolist_to_binary([term(V) || V <- L]))/binary>>;
term(T) when is_tuple(T)   -> Vs = tuple_to_list(T),
                              <<5, (length(Vs)):32,
                                (iolist_to_binary([term(V) || V <- Vs]))/binary>>;
term(M) when is_map(M)     -> Ps = maps:to_list(M),
                              <<6, (length(Ps)):32,
                                (iolist_to_binary([[term(K), term(V)]
                                                   || {K, V} <- Ps]))/binary>>.

%% A 64-bit two's complement field would do, but zigzag keeps a small negative
%% number small, and most of what an image holds is small.
zigzag(I) when I >= 0 -> I * 2;
zigzag(I)             -> -I * 2 - 1.

unzigzag(U) when U band 1 =:= 0 -> U div 2;
unzigzag(U)                     -> -((U + 1) div 2).

%%% --------------------------------------------------------------- decode ---

-doc """
Read an image, or say why it is not one.

`Max` bounds the decompressed size and must come from the **module**, not from
the file: a length a planted file supplies is not a bound on anything.

Every failure is the same shape, and a caller is expected to treat all of them
as a miss rather than an error, which is what `wasm_code_cache` promises for
its own reads and does not deliver.
""".
-spec decode(binary(), non_neg_integer()) ->
          {ok, parts()} | {error, wasm_error:error()}.
decode(<<?MAGIC, Format:16, _Abi:32, _/binary>>, _Max) when Format =/= ?FORMAT ->
    refuse(snapshot_format_unknown, ~"this image was written by another format",
           #{found => Format, expected => ?FORMAT});
decode(<<?MAGIC, ?FORMAT:16, Abi:32, _/binary>>, _Max) when Abi =/= ?IMAGE_ABI ->
    refuse(snapshot_abi_mismatch, ~"this image was written by another runtime",
           #{found => Abi, expected => ?IMAGE_ABI});
decode(<<?MAGIC, ?FORMAT:16, ?IMAGE_ABI:32, Len:32, Digest:32/binary,
         Rest/binary>>, Max) ->
    %% The length is checked before the payload is taken, so a truncated file
    %% is a refusal rather than a short digest over whatever arrived.
    case byte_size(Rest) of
        Len -> digest(Digest, Rest, Max);
        Got -> refuse(snapshot_truncated, ~"the image is not its stated length",
                      #{expected => Len, got => Got})
    end;
decode(_Other, _Max) ->
    refuse(snapshot_not_an_image, ~"this is not a snapshot image", #{}).

digest(Digest, Payload, Max) ->
    case crypto:hash(sha256, Payload) of
        Digest -> payload(Payload, Max);
        _      -> refuse(snapshot_corrupt, ~"the image does not match its digest",
                         #{})
    end.

payload(<<Codec, Raw:32, Stored/binary>>, Max) when Raw =< Max ->
    case inflate(Codec, Stored, Raw) of
        {ok, Body}     -> sections(Body, #{});
        {error, _} = E -> E
    end;
payload(<<_Codec, Raw:32, _/binary>>, Max) ->
    %% Refused **before** allocating, which is the whole point of taking the
    %% ceiling from the module rather than the file.
    refuse(snapshot_too_large, ~"the image claims more than the module allows",
           #{claimed => Raw, allowed => Max});
payload(_Other, _Max) ->
    refuse(snapshot_not_an_image, ~"the image has no payload header", #{}).

inflate(?CODEC_RAW, Body, Raw) when byte_size(Body) =:= Raw ->
    {ok, Body};
inflate(?CODEC_ZLIB, Stored, Raw) ->
    try zlib:uncompress(Stored) of
        Body when byte_size(Body) =:= Raw -> {ok, Body};
        _ -> refuse(snapshot_corrupt, decompress_length_msg(),
                    #{expected => Raw})
    catch _:_ ->
        refuse(snapshot_corrupt, ~"the image did not decompress", #{})
    end;
inflate(Codec, _Stored, _Raw) ->
    refuse(snapshot_codec_unknown, ~"this image uses a codec this build has not",
           #{codec => Codec}).

sections(<<>>, Acc) ->
    complete(Acc);
sections(<<Tag, Len:32, Rest/binary>>, Acc) when byte_size(Rest) >= Len ->
    <<Data:Len/binary, Tail/binary>> = Rest,
    case section(Tag, Data, Acc) of
        {ok, Acc2}     -> sections(Tail, Acc2);
        {error, _} = E -> E
    end;
sections(_Other, _Acc) ->
    refuse(snapshot_corrupt, ~"a section runs past the end of the image", #{}).

section(?S_HASH, <<Hash:32/binary>>, Acc) -> {ok, Acc#{hash => Hash}};
section(?S_HASH, _Other, _Acc) ->
    refuse(snapshot_corrupt, ~"the module hash is not 32 bytes", #{});
section(?S_VERSION, Bin, Acc) -> {ok, Acc#{version => Bin}};
section(Tag, Bin, Acc) ->
    case unterm(Bin) of
        {ok, V, <<>>}  -> {ok, keyed(Tag, V, Acc)};
        {ok, _V, _R}   -> refuse(snapshot_corrupt, ~"a section has trailing bytes",
                                 #{section => Tag});
        {error, _} = E -> E
    end.

keyed(?S_KEY, V, Acc)     -> Acc#{key => V};
keyed(?S_SHAPE, V, Acc)   -> Acc#{shape => V};
keyed(?S_GLOBALS, V, Acc) -> Acc#{globals => V};
keyed(?S_TABLES, V, Acc)  -> Acc#{tables => V};
keyed(?S_MEMS, V, Acc)    -> Acc#{mems => V};
keyed(?S_DROPPED, V, Acc) -> Acc#{dropped => V};
keyed(?S_HOOKS, V, Acc)   -> Acc#{hooks => V};
%% An unknown section is **not** ignored. Skipping one would let a newer writer
%% hand this build an image whose meaning it does not have, which the ABI check
%% exists to prevent and this would quietly undo.
keyed(Tag, _V, Acc)       -> Acc#{{unknown, Tag} => true}.

complete(Acc) ->
    Want = [hash, version, key, shape, globals, tables, mems, dropped, hooks],
    case [K || K <- Want, not maps:is_key(K, Acc)] of
        [] -> mems_shaped(Acc);
        Missing -> refuse(snapshot_corrupt, ~"the image is missing a section",
                          #{missing => Missing})
    end.

%% `mems` is the one part whose inner shape the value encoding cannot express,
%% so it is checked here rather than trusted.
mems_shaped(#{mems := Mems} = Acc) ->
    case lists:all(fun({P, Rs}) when is_integer(P), P >= 0, is_list(Rs) ->
                           lists:all(fun({O, B}) -> is_integer(O) andalso O >= 0
                                                    andalso is_binary(B);
                                        (_) -> false
                                     end, Rs);
                      (_) -> false
                   end, Mems) of
        true ->
            {ok, Acc#{mems => [#{pages => P, runs => Rs} || {P, Rs} <- Mems]}};
        false ->
            refuse(snapshot_corrupt, ~"a memory in the image is malformed", #{})
    end;
mems_shaped(_Acc) ->
    refuse(snapshot_corrupt, ~"the image has no memories section", #{}).

unterm(<<0, U:64, R/binary>>) -> {ok, unzigzag(U), R};
unterm(<<1, F:64/float, R/binary>>) -> {ok, F, R};
unterm(<<2, L:32, B:L/binary, R/binary>>) -> {ok, B, R};
unterm(<<3, L:16, N:L/binary, R/binary>>) ->
    %% **Existing only.** A name this node has never seen is refused rather
    %% than interned: the atom table is node-wide and never reclaimed, and a
    %% file in a directory is exactly where a guest-shaped name would be
    %% planted.
    %%
    %% `own_atoms/0' below is why "existing" is not a lottery for the names the
    %% runtime itself writes.
    try {ok, binary_to_existing_atom(N, utf8), R}
    catch error:badarg ->
        refuse(snapshot_unknown_atom, unknown_atom_msg(), #{name => N})
    end;
unterm(<<4, N:32, R/binary>>) -> collect(N, R, [], fun(Vs) -> Vs end);
unterm(<<5, N:32, R/binary>>) -> collect(N, R, [], fun list_to_tuple/1);
unterm(<<6, N:32, R/binary>>) -> collect(N * 2, R, [], fun pairs/1);
unterm(_Other) ->
    refuse(snapshot_corrupt, no_encoding_msg(), #{}).

%% Adjacent sigils do not concatenate, and a message long enough to want two
%% lines is clearer as its own function anyway.
decompress_length_msg() ->
    <<"the image did not decompress to its stated length">>.

unknown_atom_msg() ->
    <<"the image names an atom this node does not have">>.

no_encoding_msg() ->
    <<"the image holds a value this format has no encoding for">>.

collect(0, R, Acc, Done) ->
    {ok, Done(lists:reverse(Acc)), R};
collect(N, R, Acc, Done) ->
    case unterm(R) of
        {ok, V, R2}    -> collect(N - 1, R2, [V | Acc], Done);
        {error, _} = E -> E
    end.

pairs(Vs) -> maps:from_list(pairs_(Vs)).

pairs_([]) -> [];
pairs_([K, V | Rest]) -> [{K, V} | pairs_(Rest)].

refuse(Kind, Msg, Ctx) ->
    {error, #{class => malformed, kind => Kind, msg => Msg, ctx => Ctx}}.
