%% @doc The network capability, on its own.
%%
%% `wasi_net' decides which addresses an instance may reach. That decision is
%% the whole of socket security here, so it is tested directly rather than
%% through a syscall: a matcher that is wrong about `::ffff:127.0.0.1' is wrong
%% whether or not any test happens to send a packet.
%%
%% The escapes each get a case. They are the shapes an address can take that
%% mean one thing to a tuple comparison and another to the network stack.
-module(wasi_net_SUITE).

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

all() ->
    [absent_grant_permits_nothing,
     an_empty_grant_permits_nothing,
     an_exact_host_and_port,
     a_network_and_a_port_range,
     host_bits_in_a_rule_are_ignored,
     protocols_are_separate,
     connect_and_listen_are_separate,
     ipv4_mapped_ipv6_is_the_same_address,
     ipv4_compatible_addresses_are_not_folded,
     families_do_not_cross,
     a_wider_bind_than_the_grant_is_refused,
     port_zero_is_not_a_wildcard,
     bindable_names_only_concrete_rules,
     resolve_is_off_unless_granted,
     limits_have_defaults,
     a_malformed_grant_is_a_configuration_error].

%%% ----------------------------------------------------------------- basics ---

absent_grant_permits_nothing(_Config) ->
    G = wasi_net:grant(none),
    ?assertEqual(none, G),
    ?assertNot(wasi_net:allows(connect, {tcp, {127, 0, 0, 1}, 80}, G)),
    ?assertNot(wasi_net:allows(listen, {tcp, {127, 0, 0, 1}, 80}, G)),
    ?assertNot(wasi_net:resolves(G)),
    ?assertEqual(0, wasi_net:max_sockets(G)),
    ?assertEqual([], wasi_net:bindable(G)).

%% `#{net => #{}}' is exactly as refused as no `net' key at all. A grant that
%% names nothing grants nothing; there is no default list.
an_empty_grant_permits_nothing(_Config) ->
    G = wasi_net:grant(#{}),
    ?assertNot(wasi_net:allows(connect, {tcp, {127, 0, 0, 1}, 80}, G)),
    ?assertNot(wasi_net:allows(listen, {tcp, {127, 0, 0, 1}, 80}, G)),
    ?assertNot(wasi_net:resolves(G)).

an_exact_host_and_port(_Config) ->
    G = wasi_net:grant(#{connect => [{tcp, ~"127.0.0.1", 8080}]}),
    ?assert(wasi_net:allows(connect, {tcp, {127, 0, 0, 1}, 8080}, G)),
    ?assertNot(wasi_net:allows(connect, {tcp, {127, 0, 0, 1}, 8081}, G)),
    ?assertNot(wasi_net:allows(connect, {tcp, {127, 0, 0, 2}, 8080}, G)).

a_network_and_a_port_range(_Config) ->
    G = wasi_net:grant(#{connect => [{tcp, ~"10.0.0.0/8", {8000, 8099}}]}),
    ?assert(wasi_net:allows(connect, {tcp, {10, 1, 2, 3}, 8000}, G)),
    ?assert(wasi_net:allows(connect, {tcp, {10, 255, 255, 255}, 8099}, G)),
    ?assertNot(wasi_net:allows(connect, {tcp, {11, 0, 0, 1}, 8000}, G)),
    ?assertNot(wasi_net:allows(connect, {tcp, {10, 1, 2, 3}, 8100}, G)),
    ?assertNot(wasi_net:allows(connect, {tcp, {10, 1, 2, 3}, 7999}, G)).

%% A rule written with host bits set means the network it names, not nothing.
host_bits_in_a_rule_are_ignored(_Config) ->
    G = wasi_net:grant(#{connect => [{tcp, ~"10.1.2.3/8", any}]}),
    ?assert(wasi_net:allows(connect, {tcp, {10, 0, 0, 1}, 443}, G)).

protocols_are_separate(_Config) ->
    G = wasi_net:grant(#{connect => [{udp, ~"10.0.0.1", 53}]}),
    ?assert(wasi_net:allows(connect, {udp, {10, 0, 0, 1}, 53}, G)),
    ?assertNot(wasi_net:allows(connect, {tcp, {10, 0, 0, 1}, 53}, G)).

%% Outbound and inbound are different capabilities. Granting one grants nothing
%% of the other, in either direction.
connect_and_listen_are_separate(_Config) ->
    Out = wasi_net:grant(#{connect => [{tcp, ~"127.0.0.1", 8080}]}),
    ?assertNot(wasi_net:allows(listen, {tcp, {127, 0, 0, 1}, 8080}, Out)),
    In = wasi_net:grant(#{listen => [{tcp, ~"127.0.0.1", 8080}]}),
    ?assertNot(wasi_net:allows(connect, {tcp, {127, 0, 0, 1}, 8080}, In)).

%%% ---------------------------------------------------------------- escapes ---

%% The one a tuple comparison misses. `::ffff:127.0.0.1' reaches the same host
%% as `127.0.0.1', so it has to match the same rule, and a rule written in the
%% mapped notation has to match a plain IPv4 address for the same reason.
ipv4_mapped_ipv6_is_the_same_address(_Config) ->
    V4 = wasi_net:grant(#{connect => [{tcp, ~"127.0.0.0/8", 80}]}),
    Mapped = {0, 0, 0, 0, 0, 16#ffff, 16#7f00, 16#0001},
    ?assert(wasi_net:allows(connect, {tcp, Mapped, 80}, V4)),
    %% And the reverse: a mapped grant is an IPv4 grant.
    G = wasi_net:grant(#{connect => [{tcp, ~"::ffff:127.0.0.1", 80}]}),
    ?assert(wasi_net:allows(connect, {tcp, {127, 0, 0, 1}, 80}, G)),
    %% Including as a network, where the prefix loses its 96 mapping bits.
    Net = wasi_net:grant(#{connect => [{tcp, ~"::ffff:10.0.0.0/120", 80}]}),
    ?assert(wasi_net:allows(connect, {tcp, {10, 0, 0, 5}, 80}, Net)),
    ?assertNot(wasi_net:allows(connect, {tcp, {10, 0, 1, 5}, 80}, Net)),
    %% A mapped address outside the granted network is still outside it.
    Outside = {0, 0, 0, 0, 0, 16#ffff, 16#0a00, 16#0105},
    ?assertNot(wasi_net:allows(connect, {tcp, Outside, 80}, Net)).

%% The deprecated `::a.b.c.d' block is left alone, because `::0.0.0.1' and
%% `::1' are one address and folding the block would make loopback ambiguous.
%% An IPv4 grant therefore does not cover it.
ipv4_compatible_addresses_are_not_folded(_Config) ->
    G = wasi_net:grant(#{connect => [{tcp, ~"127.0.0.0/8", 80}]}),
    Compat = {0, 0, 0, 0, 0, 0, 16#7f00, 16#0001},
    ?assertNot(wasi_net:allows(connect, {tcp, Compat, 80}, G)),
    ?assertEqual(Compat, wasi_net:normalise(Compat)),
    ?assertEqual({0, 0, 0, 0, 0, 0, 0, 1}, wasi_net:normalise({0, 0, 0, 0, 0, 0, 0, 1})).

families_do_not_cross(_Config) ->
    V4 = wasi_net:grant(#{connect => [{tcp, ~"0.0.0.0/0", any}]}),
    ?assert(wasi_net:allows(connect, {tcp, {8, 8, 8, 8}, 53}, V4)),
    %% `0.0.0.0/0' is every IPv4 address and no IPv6 one.
    ?assertNot(wasi_net:allows(connect, {tcp, {16#2001, 0, 0, 0, 0, 0, 0, 1}, 53}, V4)),
    V6 = wasi_net:grant(#{connect => [{tcp, ~"::/0", any}]}),
    ?assert(wasi_net:allows(connect, {tcp, {16#2001, 0, 0, 0, 0, 0, 0, 1}, 53}, V6)),
    ?assertNot(wasi_net:allows(connect, {tcp, {8, 8, 8, 8}, 53}, V6)).

%% Binding `0.0.0.0' publishes a service on every interface the host has. A
%% loopback grant must not permit it, which it does not, because `0.0.0.0' is
%% not inside `127.0.0.0/8'. Stated as a case because it is the mistake that
%% turns a local service into a public one.
a_wider_bind_than_the_grant_is_refused(_Config) ->
    G = wasi_net:grant(#{listen => [{tcp, ~"127.0.0.1", 8080}]}),
    ?assert(wasi_net:allows(listen, {tcp, {127, 0, 0, 1}, 8080}, G)),
    ?assertNot(wasi_net:allows(listen, {tcp, {0, 0, 0, 0}, 8080}, G)),
    ?assertNot(wasi_net:allows(listen, {tcp, {0, 0, 0, 0, 0, 0, 0, 0}, 8080}, G)).

%% Port 0 asks the operating system to choose. A rule naming a port does not
%% permit it, and only `any' does.
port_zero_is_not_a_wildcard(_Config) ->
    Named = wasi_net:grant(#{listen => [{tcp, ~"127.0.0.1", 8080}]}),
    ?assertNot(wasi_net:allows(listen, {tcp, {127, 0, 0, 1}, 0}, Named)),
    Any = wasi_net:grant(#{listen => [{tcp, ~"127.0.0.1", any}]}),
    ?assert(wasi_net:allows(listen, {tcp, {127, 0, 0, 1}, 0}, Any)),
    %% And a rule naming port 0 names port 0, not every port.
    Zero = wasi_net:grant(#{listen => [{tcp, ~"127.0.0.1", 0}]}),
    ?assert(wasi_net:allows(listen, {tcp, {127, 0, 0, 1}, 0}, Zero)),
    ?assertNot(wasi_net:allows(listen, {tcp, {127, 0, 0, 1}, 8080}, Zero)).

%%% ----------------------------------------------------------------- shapes ---

%% Only a rule naming one address and one port describes a socket the host can
%% open. A range is permission to bind within it, which is the module's to use.
bindable_names_only_concrete_rules(_Config) ->
    G = wasi_net:grant(#{listen => [{tcp, ~"127.0.0.1", 8080},
                                    {tcp, ~"10.0.0.0/8", 9000},
                                    {tcp, ~"127.0.0.1", {9000, 9100}},
                                    {udp, ~"127.0.0.1", 5353}]}),
    ?assertEqual([{tcp, {127, 0, 0, 1}, 8080}, {udp, {127, 0, 0, 1}, 5353}],
                 wasi_net:bindable(G)).

resolve_is_off_unless_granted(_Config) ->
    ?assertNot(wasi_net:resolves(wasi_net:grant(#{}))),
    ?assertNot(wasi_net:resolves(wasi_net:grant(#{resolve => deny}))),
    ?assert(wasi_net:resolves(wasi_net:grant(#{resolve => allow}))).

limits_have_defaults(_Config) ->
    G = wasi_net:grant(#{}),
    ?assertEqual(32, wasi_net:max_sockets(G)),
    ?assertEqual(30000, wasi_net:timeout(G)),
    Set = wasi_net:grant(#{max_sockets => 2, timeout => infinity}),
    ?assertEqual(2, wasi_net:max_sockets(Set)),
    ?assertEqual(infinity, wasi_net:timeout(Set)).

%% A grant is read where the import map is built, in the embedder's process, so
%% a typo is reported there rather than surfacing later as a refused
%% connection. Failing closed would be worse: it looks like a working sandbox.
a_malformed_grant_is_a_configuration_error(_Config) ->
    Bad = [~"10.0.0.0/33",              % prefix wider than the family
           ~"10.0.0.0/8/8",
           ~"not-an-address",
           ~"example.com",              % names are never addresses here
           ~"::ffff:10.0.0.0/64"],      % spans in and out of the mapped block
    [?assertError({bad_net_grant, _},
                  wasi_net:grant(#{connect => [{tcp, A, 80}]})) || A <- Bad],
    ?assertError({bad_net_grant, _},
                 wasi_net:grant(#{connect => [{sctp, ~"127.0.0.1", 80}]})),
    ?assertError({bad_net_grant, _},
                 wasi_net:grant(#{connect => [{tcp, ~"127.0.0.1", 70000}]})),
    ?assertError({bad_net_grant, _},
                 wasi_net:grant(#{connect => [{tcp, ~"127.0.0.1", {90, 80}}]})),
    ?assertError({bad_net_grant, _}, wasi_net:grant(#{resolve => sometimes})),
    ?assertError({bad_net_grant, _}, wasi_net:grant(#{max_sockets => 0})),
    ?assertError({bad_net_grant, _}, wasi_net:grant(#{connect => not_a_list})),
    ?assertError({bad_net_grant, _}, wasi_net:grant(~"everything")).
