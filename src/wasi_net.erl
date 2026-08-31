-module(wasi_net).
-moduledoc """
The network capability.

Write a grant to say which addresses and ports an instance may reach, and which
it may accept on. It is evaluated here, in one place, with no sockets in sight,
so you can test the decision directly rather than through a syscall.

```erlang
#{net => #{connect     => [{tcp, ~"10.0.0.0/8", {8000, 8099}}],
           listen      => [{tcp, ~"127.0.0.1", 8080}],
           resolve     => allow,
           max_sockets => 32,
           timeout     => 30000}}
```

Write a rule as `{Proto, Addr, Port}`. `Proto` is `tcp` or `udp`. `Addr` is an
IP tuple, a binary address, or a binary CIDR. `Port` is an integer, `{Lo, Hi}`,
or `any`.

Leave out `net` and there is no network at all. Leave out `connect` and there is
no outbound, leave out `listen` and there is no inbound, so `#{net => #{}}`
grants nothing and is refused exactly as if you had left the key out.

## You name addresses, never names

You cannot write a rule that says "example.com". A name would have to be
resolved to be checked and resolved again to be used, and the two answers can
differ. Naming addresses removes that window rather than narrowing it:
`sock_connect` checks the literal address it was handed and passes the same
parsed tuple to `gen_tcp`, so nothing between the check and the syscall can move
the target. `sock_getaddrinfo` is a separate capability, and its answers get no
authority from having been resolved.

## IPv4-mapped IPv6

`::ffff:127.0.0.1` reaches the same host as `127.0.0.1` on every stack, so a
matcher comparing tuples would let it past a `127.0.0.0/8` grant. Every address
is normalised out of the `::ffff:0:0/96` block before matching, and the
normalised form is what the caller then connects to, so the address checked and
the address used are the same one.

IPv4-*compatible* addresses (`::1.2.3.4`, the deprecated block) are not
normalised. `::0.0.0.1` and `::1` are the same address, so normalising the
block would make loopback ambiguous. They stay IPv6 and need an IPv6 rule.

## What a rule does not do

Nothing is denied implicitly. `~"0.0.0.0/0"` really does include link-local and
cloud metadata addresses, and this module will not second-guess you. Name what
you mean. See `docs/security.md`.
""".

-export([grant/1, allows/3, bindable/1, resolves/1, max_sockets/1, timeout/1]).
-export([normalise/1, parse/1]).

%% `rule/0` because `grant/0` is made of them.
-export_type([grant/0, endpoint/0, kind/0, rule/0]).

%% A cap on descriptors, for the reason the node page budget exists: without
%% one, a module opens sockets until the node runs out of them.
-define(DEFAULT_MAX_SOCKETS, 32).
-define(DEFAULT_TIMEOUT, 30000).

-doc "A parsed grant. `none` is no network at all.".
-nominal grant() :: none | #{connect := [rule()],
                             listen := [rule()],
                             resolve := boolean(),
                             max_sockets := pos_integer(),
                             timeout := timeout()}.

-doc "What a socket call is asking to do.".
-nominal kind() :: connect | listen.

-doc "A concrete peer, as the syscall layer knows it.".
-nominal endpoint() :: {tcp | udp, inet:ip_address(), 0..65535}.

-type rule() :: {tcp | udp, {inet:ip_address(), 0..128}, {0..65535, 0..65535}}.

%%% ---------------------------------------------------------------- grant ---

-doc """
Parse the `net` value from a capability configuration.

It raises `{bad_net_grant, Term}` on anything it cannot read. This runs where
the import map is built, in your own process, because a typo in a CIDR is a
configuration error and you should hear about it as one rather than meeting it
later as a refused connection.
""".
-spec grant(term()) -> grant().
grant(none) -> none;
grant(undefined) -> none;
grant(Map) when is_map(Map) ->
    #{connect => rules(maps:get(connect, Map, [])),
      listen => rules(maps:get(listen, Map, [])),
      resolve => resolve(maps:get(resolve, Map, deny)),
      max_sockets => count(maps:get(max_sockets, Map, ?DEFAULT_MAX_SOCKETS)),
      timeout => wait(maps:get(timeout, Map, ?DEFAULT_TIMEOUT))};
grant(Other) ->
    erlang:error({bad_net_grant, Other}).

resolve(allow) -> true;
resolve(deny) -> false;
resolve(Other) -> erlang:error({bad_net_grant, {resolve, Other}}).

count(N) when is_integer(N), N > 0 -> N;
count(Other) -> erlang:error({bad_net_grant, {max_sockets, Other}}).

wait(infinity) -> infinity;
wait(N) when is_integer(N), N >= 0 -> N;
wait(Other) -> erlang:error({bad_net_grant, {timeout, Other}}).

rules(L) when is_list(L) -> [rule(R) || R <- L];
rules(Other) -> erlang:error({bad_net_grant, Other}).

rule({Proto, Addr, Port}) when Proto =:= tcp; Proto =:= udp ->
    {Proto, cidr(Addr), ports(Port)};
rule(Other) ->
    erlang:error({bad_net_grant, Other}).

%%% ----------------------------------------------------------------- rules ---

%% An address with no prefix length is one host: a full-width prefix.
cidr(Bin) when is_binary(Bin) ->
    case binary:split(Bin, ~"/") of
        [Addr] -> host(parse_or_fail(Addr));
        [Addr, Len] -> network(parse_or_fail(Addr), integer_or_fail(Len, Bin), Bin)
    end;
cidr(Tuple) when tuple_size(Tuple) =:= 4; tuple_size(Tuple) =:= 8 ->
    host(Tuple);
cidr(Other) ->
    erlang:error({bad_net_grant, Other}).

host(Addr0) ->
    Addr = normalise(Addr0),
    {Addr, width(Addr)}.

%% The prefix length is written in the notation the address was written in, so
%% a mapped base has to have its 96 mapping bits taken off with it. Below 96 the
%% prefix spans addresses inside and outside the mapped block at once, which has
%% no IPv4 meaning; refuse rather than guess which half was meant.
network(Addr, Bits, Written) ->
    case normalise(Addr) of
        Addr when tuple_size(Addr) =:= 4, Bits >= 0, Bits =< 32 ->
            {mask(Addr, Bits), Bits};
        Addr when tuple_size(Addr) =:= 8, Bits >= 0, Bits =< 128 ->
            {mask(Addr, Bits), Bits};
        V4 when Bits >= 96, Bits =< 128 ->
            {mask(V4, Bits - 96), Bits - 96};
        _ ->
            erlang:error({bad_net_grant, Written})
    end.

ports(any) -> {0, 65535};
ports(P) when is_integer(P), P >= 0, P =< 65535 -> {P, P};
ports({Lo, Hi}) when is_integer(Lo), is_integer(Hi), Lo >= 0, Lo =< Hi,
                     Hi =< 65535 -> {Lo, Hi};
ports(Other) -> erlang:error({bad_net_grant, {port, Other}}).

parse_or_fail(Bin) ->
    case parse(Bin) of
        {ok, Addr} -> Addr;
        error -> erlang:error({bad_net_grant, Bin})
    end.

integer_or_fail(Bin, Written) ->
    try binary_to_integer(Bin)
    catch _:_ -> erlang:error({bad_net_grant, Written})
    end.

%%% -------------------------------------------------------------- matching ---

-doc """
Ask whether the grant permits this endpoint, for this kind of use.

`connect` and `listen` are separate lists and neither implies the other. An
accepted connection is not checked against `connect`: inbound is not outbound,
and you granted the listener it arrived on already.
""".
-spec allows(kind(), endpoint(), grant()) -> boolean().
allows(_Kind, _Endpoint, none) ->
    false;
allows(Kind, {Proto, Addr, Port}, Grant)
  when Kind =:= connect; Kind =:= listen ->
    Norm = normalise(Addr),
    lists:any(fun(Rule) -> matches(Rule, Proto, Norm, Port) end,
              maps:get(Kind, Grant)).

matches({Proto, {Net, Bits}, {Lo, Hi}}, Proto, Addr, Port)
  when Port >= Lo, Port =< Hi ->
    %% Families are compared after normalisation, so a v4 rule never matches a
    %% real IPv6 address and a mapped address is matched as the IPv4 one it is.
    tuple_size(Addr) =:= tuple_size(Net) andalso mask(Addr, Bits) =:= Net;
matches(_Rule, _Proto, _Addr, _Port) ->
    false.

-doc """
The endpoints the host should open a listening socket on.

Only a rule naming one address and one port describes something bindable. A CIDR
or a port range is permission for the module to bind within it, which is the
extension's business, not a socket the host can open on its behalf.
""".
-spec bindable(grant()) -> [endpoint()].
bindable(none) ->
    [];
bindable(#{listen := Rules}) ->
    [{Proto, Addr, Port}
     || {Proto, {Addr, Bits}, {Port, Port}} <- Rules, Bits =:= width(Addr)].

-doc "Is `sock_getaddrinfo` granted?".
-spec resolves(grant()) -> boolean().
resolves(none) -> false;
resolves(#{resolve := R}) -> R.

-doc "How many sockets an instance may hold open at once.".
-spec max_sockets(grant()) -> non_neg_integer().
max_sockets(none) -> 0;
max_sockets(#{max_sockets := N}) -> N.

-doc "How long a blocking socket operation may wait.".
-spec timeout(grant()) -> timeout().
timeout(none) -> 0;
timeout(#{timeout := T}) -> T.

%%% -------------------------------------------------------------- addresses ---

-doc """
Parse a textual address. It takes everything `inet:parse_address/1` does, and
normalises the result.
""".
-spec parse(binary() | string()) -> {ok, inet:ip_address()} | error.
parse(Bin) when is_binary(Bin) -> parse(binary_to_list(Bin));
parse(Str) when is_list(Str) ->
    case inet:parse_address(Str) of
        {ok, Addr} -> {ok, normalise(Addr)};
        {error, _} -> error
    end.

-doc """
Fold an IPv4-mapped IPv6 address onto the IPv4 address it reaches.

You get everything else back unchanged, including the IPv4-compatible block:
`::0.0.0.1` and `::1` are the same address, so folding that block would make
loopback ambiguous.
""".
-spec normalise(inet:ip_address()) -> inet:ip_address().
normalise({0, 0, 0, 0, 0, 16#ffff, X, Y}) ->
    {X bsr 8, X band 16#ff, Y bsr 8, Y band 16#ff};
normalise(Addr) ->
    Addr.

width(Addr) when tuple_size(Addr) =:= 4 -> 32;
width(Addr) when tuple_size(Addr) =:= 8 -> 128.

%% Zeroing the host bits, so a rule written `10.1.2.3/8` means the same network
%% as `10.0.0.0/8` rather than never matching anything.
mask(Addr, Bits) ->
    W = width(Addr),
    from_int(to_int(Addr) band (((1 bsl Bits) - 1) bsl (W - Bits)), W).

to_int(Addr) ->
    Size = part_size(Addr),
    lists:foldl(fun(P, Acc) -> (Acc bsl Size) bor P end, 0, tuple_to_list(Addr)).

from_int(N, 32) ->
    <<A, B, C, D>> = <<N:32>>,
    {A, B, C, D};
from_int(N, 128) ->
    <<A:16, B:16, C:16, D:16, E:16, F:16, G:16, H:16>> = <<N:128>>,
    {A, B, C, D, E, F, G, H}.

part_size(Addr) when tuple_size(Addr) =:= 4 -> 8;
part_size(Addr) when tuple_size(Addr) =:= 8 -> 16.
