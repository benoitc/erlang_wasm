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

-export([encode/1, decode/2, limits/0, representable/2]).
-export([own_atoms/0]).
-export([format_version/0, image_abi/0]).

-type limits() :: #{stored := pos_integer(), inflated := pos_integer(),
                    depth := pos_integer(), nodes := pos_integer()}.
-export_type([limits/0]).

%% Operator ceilings, generous for a real image (a started CPython is ~2.7 MB
%% stored / ~42 MB inflated) and tight against abuse. Bytes, then decode depth
%% and total decoded nodes; the two byte limits are capped to the 32-bit fields
%% the format actually has.
-define(DEF_STORED, (256 bsl 20)).            %% 256 MiB
-define(DEF_INFLATED, (1 bsl 30)).            %% 1 GiB
-define(DEF_DEPTH, 64).
-define(DEF_NODES, 16000000).
-define(U32_MAX, ((1 bsl 32) - 1)).

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
-spec decode(binary(), limits()) ->
          {ok, parts()} | {error, wasm_error:error()}.
decode(<<?MAGIC, Format:16, _Abi:32, _/binary>>, _Lim) when Format =/= ?FORMAT ->
    refuse(snapshot_format_unknown, ~"this image was written by another format",
           #{found => Format, expected => ?FORMAT});
decode(<<?MAGIC, ?FORMAT:16, Abi:32, _/binary>>, _Lim) when Abi =/= ?IMAGE_ABI ->
    refuse(snapshot_abi_mismatch, ~"this image was written by another runtime",
           #{found => Abi, expected => ?IMAGE_ABI});
decode(<<?MAGIC, ?FORMAT:16, ?IMAGE_ABI:32, Len:32, _Digest:32/binary,
         _Rest/binary>>, #{stored := Stored}) when Len > Stored ->
    %% The stored payload is refused before it is read, on an operator ceiling
    %% rather than a length the file itself supplies.
    refuse(snapshot_too_large, ~"the image's stored payload exceeds the ceiling",
           #{claimed => Len, allowed => Stored});
decode(<<?MAGIC, ?FORMAT:16, ?IMAGE_ABI:32, Len:32, Digest:32/binary,
         Rest/binary>>, Lim) ->
    %% The length is checked before the payload is taken, so a truncated file
    %% is a refusal rather than a short digest over whatever arrived.
    case byte_size(Rest) of
        Len -> digest(Digest, Rest, Lim);
        Got -> refuse(snapshot_truncated, ~"the image is not its stated length",
                      #{expected => Len, got => Got})
    end;
decode(_Other, _Lim) ->
    refuse(snapshot_not_an_image, ~"this is not a snapshot image", #{}).

digest(Digest, Payload, Lim) ->
    case crypto:hash(sha256, Payload) of
        Digest -> payload(Payload, Lim);
        _      -> refuse(snapshot_corrupt, ~"the image does not match its digest",
                         #{})
    end.

payload(<<Codec, Raw:32, Stored/binary>>, #{inflated := Max} = Lim)
  when Raw =< Max ->
    case inflate(Codec, Stored, Raw) of
        {ok, Body}     -> sections(Body, #{}, Lim);
        {error, _} = E -> E
    end;
payload(<<_Codec, Raw:32, _/binary>>, #{inflated := Max}) ->
    %% Refused **before** allocating, on the operator's inflated ceiling.
    refuse(snapshot_too_large, ~"the image's inflated size exceeds the ceiling",
           #{claimed => Raw, allowed => Max});
payload(_Other, _Lim) ->
    refuse(snapshot_not_an_image, ~"the image has no payload header", #{}).

inflate(?CODEC_RAW, Body, Raw) when byte_size(Body) =:= Raw ->
    {ok, Body};
inflate(?CODEC_ZLIB, Stored, Raw) ->
    %% Streamed rather than `zlib:uncompress/1', which would decompress the
    %% whole stream before its size was checked: an image can claim `Raw = 1'
    %% and ship a body that expands to gigabytes. Output is accumulated one
    %% bounded chunk at a time and abandoned the moment it would exceed the
    %% ceiling the caller already gated `Raw' against.
    Z = zlib:open(),
    try
        zlib:inflateInit(Z),
        stream_inflate(zlib:safeInflate(Z, Stored), Z, Raw, [], 0)
    catch _:_ ->
        refuse(snapshot_corrupt, ~"the image did not decompress", #{})
    after
        zlib:close(Z)
    end;
inflate(Codec, _Stored, _Raw) ->
    refuse(snapshot_codec_unknown, ~"this image uses a codec this build has not",
           #{codec => Codec}).

stream_inflate({continue, Out}, Z, Raw, Acc, N) ->
    N1 = N + iolist_size(Out),
    case N1 > Raw of
        true  -> refuse(snapshot_corrupt, decompress_length_msg(),
                        #{expected => Raw});
        false -> stream_inflate(zlib:safeInflate(Z, []), Z, Raw, [Acc, Out], N1)
    end;
stream_inflate({finished, Out}, _Z, Raw, Acc, _N) ->
    Body = iolist_to_binary([Acc, Out]),
    case byte_size(Body) =:= Raw of
        true  -> {ok, Body};
        false -> refuse(snapshot_corrupt, decompress_length_msg(),
                        #{expected => Raw})
    end.

%% `Lim` carries the decode depth ceiling and the remaining node budget, which
%% is spent **across all sections** so a wide value anywhere cannot exhaust the
%% heap regardless of how the bytes are split into sections.
sections(<<>>, Acc, _Lim) ->
    complete(Acc);
sections(<<Tag, Len:32, Rest/binary>>, Acc, Lim) when byte_size(Rest) >= Len ->
    <<Data:Len/binary, Tail/binary>> = Rest,
    case section(Tag, Data, Acc, Lim) of
        {ok, Acc2, Lim2} -> sections(Tail, Acc2, Lim2);
        {error, _} = E   -> E
    end;
sections(_Other, _Acc, _Lim) ->
    refuse(snapshot_corrupt, ~"a section runs past the end of the image", #{}).

%% A section whose key is already set is a duplicate: the image was built by
%% hand to have two of something, and taking the second silently would let it
%% smuggle a value past whatever validated the first.
section(Tag, Bin, Acc, Lim) ->
    case key_for(Tag) of
        {unknown, _} = U ->
            refuse(snapshot_corrupt, ~"the image has an unknown section",
                   #{section => Tag, key => U});
        Key ->
            case maps:is_key(Key, Acc) of
                true ->
                    refuse(snapshot_corrupt, ~"the image has a duplicate section",
                           #{section => Tag});
                false ->
                    section_value(Tag, Key, Bin, Acc, Lim)
            end
    end.

key_for(?S_HASH)    -> hash;
key_for(?S_VERSION) -> version;
key_for(?S_KEY)     -> key;
key_for(?S_SHAPE)   -> shape;
key_for(?S_GLOBALS) -> globals;
key_for(?S_TABLES)  -> tables;
key_for(?S_MEMS)    -> mems;
key_for(?S_DROPPED) -> dropped;
key_for(?S_HOOKS)   -> hooks;
key_for(Tag)        -> {unknown, Tag}.

section_value(?S_HASH, hash, <<Hash:32/binary>>, Acc, Lim) ->
    {ok, Acc#{hash => Hash}, Lim};
section_value(?S_HASH, hash, _Other, _Acc, _Lim) ->
    refuse(snapshot_corrupt, ~"the module hash is not 32 bytes", #{});
%% The version is raw section bytes, so it is a binary by construction.
section_value(?S_VERSION, version, Bin, Acc, Lim) ->
    {ok, Acc#{version => Bin}, Lim};
section_value(Tag, Key, Bin, Acc, #{depth := D, nodes := N} = Lim) ->
    case unterm(Bin, D, N) of
        {ok, V, <<>>, N2} -> {ok, Acc#{Key => V}, Lim#{nodes := N2}};
        {ok, _V, _R, _N2} -> refuse(snapshot_corrupt,
                                    ~"a section has trailing bytes",
                                    #{section => Tag});
        {error, _} = E    -> E
    end.

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

%% `Depth' is how much nesting is still allowed and `Budget' how many decoded
%% nodes remain: a small but deeply nested term cannot exhaust the stack, and a
%% shallow but very wide collection cannot exhaust the heap, even though both
%% fit under the inflated-bytes ceiling.
unterm(_Bin, Depth, _Budget) when Depth =< 0 ->
    refuse(snapshot_too_deep, ~"the image nests deeper than allowed", #{});
unterm(_Bin, _Depth, Budget) when Budget =< 0 ->
    refuse(snapshot_too_many_nodes, ~"the image decodes to more nodes than allowed",
           #{});
unterm(<<0, U:64, R/binary>>, _D, Budget) -> {ok, unzigzag(U), R, Budget - 1};
unterm(<<1, F:64/float, R/binary>>, _D, Budget) -> {ok, F, R, Budget - 1};
unterm(<<2, L:32, B:L/binary, R/binary>>, _D, Budget) -> {ok, B, R, Budget - 1};
unterm(<<3, L:16, N:L/binary, R/binary>>, _D, Budget) ->
    %% **Existing only.** A name this node has never seen is refused rather
    %% than interned: the atom table is node-wide and never reclaimed, and a
    %% file in a directory is exactly where a guest-shaped name would be
    %% planted.
    %%
    %% `own_atoms/0' below is why "existing" is not a lottery for the names the
    %% runtime itself writes.
    try {ok, binary_to_existing_atom(N, utf8), R, Budget - 1}
    catch error:badarg ->
        refuse(snapshot_unknown_atom, unknown_atom_msg(), #{name => N})
    end;
unterm(<<4, N:32, R/binary>>, D, Budget) ->
    collect(N, R, [], fun(Vs) -> Vs end, D - 1, Budget - 1);
unterm(<<5, N:32, R/binary>>, D, Budget) ->
    collect(N, R, [], fun list_to_tuple/1, D - 1, Budget - 1);
unterm(<<6, N:32, R/binary>>, D, Budget) ->
    collect(N * 2, R, [], fun pairs/1, D - 1, Budget - 1);
unterm(_Other, _D, _Budget) ->
    refuse(snapshot_corrupt, no_encoding_msg(), #{}).

%% Adjacent sigils do not concatenate, and a message long enough to want two
%% lines is clearer as its own function anyway.
decompress_length_msg() ->
    <<"the image did not decompress to its stated length">>.

unknown_atom_msg() ->
    <<"the image names an atom this node does not have">>.

no_encoding_msg() ->
    <<"the image holds a value this format has no encoding for">>.

collect(_N, _R, _Acc, _Done, _D, Budget) when Budget =< 0 ->
    refuse(snapshot_too_many_nodes, ~"the image decodes to more nodes than allowed",
           #{});
collect(0, R, Acc, Done, _D, Budget) ->
    {ok, Done(lists:reverse(Acc)), R, Budget};
collect(N, R, Acc, Done, D, Budget) ->
    case unterm(R, D, Budget) of
        {ok, V, R2, Budget2} -> collect(N - 1, R2, [V | Acc], Done, D, Budget2);
        {error, _} = E       -> E
    end.

pairs(Vs) -> maps:from_list(pairs_(Vs)).

pairs_([]) -> [];
pairs_([K, V | Rest]) -> [{K, V} | pairs_(Rest)].

%% The four ceilings, from app env, validated: a malformed value is a named
%% refusal rather than a silent default or a raise out of the public API. The
%% byte limits are clamped to the 32-bit length fields the format has, so a
%% ceiling can never authorise a size the format cannot even represent.
-spec limits() -> {ok, limits()} | {error, wasm_error:error()}.
limits() ->
    Read = [{stored, max_snapshot_stored_bytes, ?DEF_STORED, ?U32_MAX},
            {inflated, max_snapshot_inflated_bytes, ?DEF_INFLATED, ?U32_MAX},
            {depth, max_snapshot_decode_depth, ?DEF_DEPTH, infinity},
            {nodes, max_snapshot_decode_nodes, ?DEF_NODES, infinity}],
    lists:foldl(
      fun(_, {error, _} = E) -> E;
         ({Key, Env, Def, Cap}, {ok, Acc}) ->
              case one_limit(Env, Def, Cap) of
                  {ok, V}        -> {ok, Acc#{Key => V}};
                  {error, _} = E -> E
              end
      end, {ok, #{}}, Read).

one_limit(Env, Def, Cap) ->
    case application:get_env(wasm, Env, Def) of
        V when is_integer(V), V > 0 -> {ok, clamp(V, Cap)};
        Bad ->
            refuse(snapshot_config_invalid,
                   ~"a snapshot size ceiling is not a positive integer",
                   #{setting => Env, value => Bad})
    end.

clamp(V, infinity) -> V;
clamp(V, Cap)      -> min(V, Cap).

%% What `save_snapshot' checks before it writes: every value is representable in
%% the format (an integer that fits the 64-bit zigzag field, a length that fits
%% its 32-bit field, no improper list or unencodable term), and the encoded
%% payload and inflated body stay under the same ceilings load enforces. The
%% depth/node walk is the *same* one `decode' counts with, so the two sides
%% cannot drift.
-spec representable(parts(), limits()) -> ok | {error, wasm_error:error()}.
representable(#{key := Key, shape := Shape, globals := Gs, tables := Ts,
                dropped := Dropped, hooks := Hooks} = Parts,
             #{depth := D, nodes := N} = Lim) ->
    Values = [Key, Shape, Gs, Ts, Dropped, Hooks],
    case walk_terms(Values, D, N) of
        {error, _} = E -> E;
        ok             -> representable_size(Parts, Lim)
    end.

representable_size(Parts, #{stored := Stored, inflated := Inflated}) ->
    Body = body(Parts),
    Bsz = byte_size(Body),
    {_Codec, StoredBin} = compress(Body),
    Psz = 1 + 4 + byte_size(StoredBin),          %% codec + raw len + stored
    if
        Bsz > Inflated ->
            refuse(snapshot_too_large,
                   ~"the image's inflated size exceeds the ceiling",
                   #{size => Bsz, allowed => Inflated});
        Psz > Stored ->
            refuse(snapshot_too_large,
                   ~"the image's stored payload exceeds the ceiling",
                   #{size => Psz, allowed => Stored});
        true -> ok
    end.

walk_terms([], _D, _N) -> ok;
walk_terms([V | Rest], D, N) ->
    case walk_term(V, D, N) of
        {ok, N2}       -> walk_terms(Rest, D, N2);
        {error, _} = E -> E
    end.

walk_term(_V, D, _N) when D =< 0 ->
    refuse(snapshot_too_deep, ~"the image nests deeper than allowed", #{});
walk_term(_V, _D, N) when N =< 0 ->
    refuse(snapshot_too_many_nodes,
           ~"the image decodes to more nodes than allowed", #{});
walk_term(I, _D, N) when is_integer(I) ->
    case I >= -(1 bsl 63) andalso I < (1 bsl 63) of
        true  -> {ok, N - 1};
        false -> refuse(snapshot_not_representable,
                        ~"an integer does not fit the format's 64-bit field",
                        #{value => I})
    end;
walk_term(F, _D, N) when is_float(F)  -> {ok, N - 1};
walk_term(B, _D, N) when is_binary(B) -> length_ok(byte_size(B), N);
walk_term(A, _D, N) when is_atom(A)   -> {ok, N - 1};
walk_term(L, D, N) when is_list(L)    ->
    case length_ok(length_proper(L), N) of
        {error, _} = E -> E;
        {ok, N1}       -> walk_children(L, D - 1, N1)
    end;
walk_term(T, D, N) when is_tuple(T)   ->
    Vs = tuple_to_list(T),
    case length_ok(length(Vs), N) of
        {error, _} = E -> E;
        {ok, N1}       -> walk_children(Vs, D - 1, N1)
    end;
walk_term(M, D, N) when is_map(M)     ->
    Ps = lists:append([[K, V] || {K, V} <- maps:to_list(M)]),
    case length_ok(maps:size(M), N) of
        {error, _} = E -> E;
        {ok, N1}       -> walk_children(Ps, D - 1, N1)
    end;
walk_term(_Other, _D, _N) ->
    refuse(snapshot_not_representable, no_encoding_msg(), #{}).

%% A proper list gives its length; an improper one is a term the format has no
%% encoding for and is refused by returning a sentinel that fails `length_ok'.
length_proper(L) ->
    try length(L) catch error:badarg -> improper end.

length_ok(improper, _N) ->
    refuse(snapshot_not_representable, ~"an improper list cannot be encoded", #{});
length_ok(Len, _N) when Len > ?U32_MAX ->
    refuse(snapshot_not_representable,
           ~"a collection is longer than the format's 32-bit field",
           #{length => Len});
length_ok(_Len, N) -> {ok, N - 1}.

walk_children([], _D, N) -> {ok, N};
walk_children([V | Rest], D, N) ->
    case walk_term(V, D, N) of
        {ok, N2}       -> walk_children(Rest, D, N2);
        {error, _} = E -> E
    end.

refuse(Kind, Msg, Ctx) ->
    {error, #{class => malformed, kind => Kind, msg => Msg, ctx => Ctx}}.
