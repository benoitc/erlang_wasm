-module(wasm_types).
-moduledoc """
Type identity: when two declared types are the same type. Read this when a cast
or an import you expected to succeed is being refused as a type mismatch.

WebAssembly's garbage collection proposal makes this non-trivial, because types
live in *recursive groups* whose members may refer to one another and to
themselves. Two questions have to be answered differently:

  * Two structurally identical types in **separate** groups are the same type.
    `(type $a (func (param f32)))` and `(type $b (func (param f32)))` are
    interchangeable, and a `(ref $a)` satisfies a `(ref $b)`.
  * Two structurally identical types in **one** group are *different* types.
    A `throw` of the first must not be caught by a `catch` naming the second.

So identity is the pair `{canonical group, position within it}`. A group
canonicalises to a structural key in which references inside the group are by
group-relative position and references outside it are by the referent's own
canonical identity, and equal keys are interned to one id.

Identity has to hold **across modules**, since one module imports a function
whose type another declared, so the interning table is node-wide and lives in
the store `wasm_engine` owns.
""".

-include("wasm.hrl").

-export([canonicalise/2, same/2, is_subtype/4, canon_supers/3]).

-doc "Canonical identity of each type index: `{GroupId, PositionInGroup}`.".
-nominal canon() :: {non_neg_integer(), non_neg_integer()}.
-export_type([canon/0]).

%%% ----------------------------------------------------------------- api ---

-doc """
Assign every type index its canonical identity.

Groups are processed in order, so by the time a group is canonicalised every
group it refers to already has an identity, and references within the group
itself are positional.
""".
-spec canonicalise([#subtype{}], [{non_neg_integer(), pos_integer()}]) ->
          tuple().
canonicalise(Types, Groups) ->
    T = list_to_tuple(Types),
    Canon = lists:foldl(fun(G, Acc) -> group(G, T, Acc) end, #{}, Groups),
    list_to_tuple([maps:get(I, Canon) || I <- lists:seq(0, tuple_size(T) - 1)]).

-doc "Whether two type indices name the same type.".
-spec same(non_neg_integer(), non_neg_integer()) -> boolean().
same(A, A) -> true;
same(_, _) -> false.

-doc """
Whether type `A` is a subtype of type `B`, following declared supertypes.

Reflexive, and transitive through `#subtype.supers`. The declaration is what
counts: two structurally identical types are not in a subtype relation unless
one declares the other, which is what `sub` exists to say.

Each step compares *canonically*, not by index. A type may declare a supertype
that is a different index from the one being asked about while naming the same
type, which is exactly what happens when two recursive groups canonicalise
together: the chain `8 -> 6 -> 2` answers a question about type 0 when 0 and 2
are the same type.
""".
-spec is_subtype(non_neg_integer(), non_neg_integer(), tuple(), tuple()) ->
          boolean().
is_subtype(A, B, Types, Canon) ->
    same_canon(A, B, Canon) orelse
        case A < tuple_size(Types) of
            false -> false;
            true ->
                #subtype{supers = Supers} = element(A + 1, Types),
                lists:any(fun(S) -> is_subtype(S, B, Types, Canon) end, Supers)
        end.

same_canon(A, B, Canon) ->
    A =:= B orelse
        (A < tuple_size(Canon) andalso B < tuple_size(Canon) andalso
         element(A + 1, Canon) =:= element(B + 1, Canon)).

-doc """
Every type `Idx` is a subtype of, canonically, including itself.

Used where a *value's* type has to be tested against a declared one and the two
may come from different modules, so indices cannot be compared.
""".
-spec canon_supers(non_neg_integer(), tuple(), tuple()) -> [canon()].
canon_supers(Idx, Types, Canon) ->
    lists:usort(walk_supers(Idx, Types, Canon, #{})).

walk_supers(Idx, Types, Canon, Seen)
  when not is_map_key(Idx, Seen), Idx < tuple_size(Types) ->
    #subtype{supers = Sup} = element(Idx + 1, Types),
    [element(Idx + 1, Canon) |
     lists:append([walk_supers(S, Types, Canon, Seen#{Idx => true})
                   || S <- Sup])];
walk_supers(_Idx, _Types, _Canon, _Seen) -> [].

%%% ------------------------------------------------------ canonicalisation ---

group({Start, N}, Types, Canon) ->
    Members = [element(Start + I + 1, Types) || I <- lists:seq(0, N - 1)],
    Key = [subtype_key(S, Start, N, Canon) || S <- Members],
    Id = wasm_engine:intern_rec_group(Key),
    lists:foldl(fun(I, Acc) -> Acc#{Start + I => {Id, I}} end,
                Canon, lists:seq(0, N - 1)).

subtype_key(#subtype{final = F, supers = Sup, body = B}, Start, N, C) ->
    {F, [ref_key(I, Start, N, C) || I <- Sup], comp_key(B, Start, N, C)}.

comp_key(#functype{params = P, results = R}, Start, N, C) ->
    {func, [val_key(T, Start, N, C) || T <- P], [val_key(T, Start, N, C) || T <- R]};
comp_key(#structtype{fields = Fs}, Start, N, C) ->
    {struct, [field_key(F, Start, N, C) || F <- Fs]};
comp_key(#arraytype{field = F}, Start, N, C) ->
    {array, field_key(F, Start, N, C)}.

field_key(#fieldtype{type = T, mut = M}, Start, N, C) ->
    {val_key(T, Start, N, C), M}.

val_key({ref, Null, {type, I}}, Start, N, C) ->
    {ref, Null, ref_key(I, Start, N, C)};
val_key(T, _Start, _N, _C) -> T.

%% A reference into this group is positional, so the group's shape is what is
%% compared rather than the indices it happens to have been given. A reference
%% out of it is the referent's canonical identity, which is already known.
ref_key(I, Start, N, _C) when I >= Start, I < Start + N -> {rec, I - Start};
ref_key(I, _Start, _N, C) -> maps:get(I, C, {unresolved, I}).
