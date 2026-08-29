%% @doc The security review for sockets: every escape route, in one place.
%%
%% `wasi_SUITE' does this for the filesystem, and the argument is the same. A
%% WASI implementation that connects to the right host is easy; one that
%% reliably refuses the wrong one is the whole product. Each route gets a case
%% that attempts it, and each must be refused with `ENOTCAPABLE', not with an
%% error that says anything about the host.
%%
%% The individual mechanisms are tested where they live: `wasi_net_SUITE' for
%% the matcher, `wasi_sock_ext_SUITE' for the syscalls. What is here is the
%% enumeration, so that reading one file tells you what was considered.
%%
%% What is *not* here is stated in `docs/security.md', and the last two cases
%% check that those statements are true rather than reassuring.
-module(wasi_net_escape_SUITE).

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include("wasi.hrl").

all() ->
    [no_grant_refuses_every_socket_call,
     a_descriptor_does_not_cross_instances,
     a_refusal_says_nothing_about_the_host,
     an_ungranted_port_is_refused_even_where_something_listens,
     a_wildcard_grant_really_is_a_wildcard,
     resolution_cannot_widen_a_grant].

%% The module is the extension suite's: it imports every socket call there is,
%% which is exactly what a sweep needs.
init_per_suite(Config) ->
    {ok, Parsed} = wasm_wat:module(wasi_sock_ext_SUITE:source()),
    {ok, Mod} = wasm_validate:module(Parsed),
    [{mod, Mod} | Config].

end_per_suite(_) -> ok.

instance(Config, Net) ->
    {ok, I} = wasm:instantiate(?config(mod, Config),
                               wasi_preview1:imports(#{net => Net})),
    I.

free_port() ->
    {ok, S} = gen_tcp:listen(0, [{ip, {127, 0, 0, 1}}]),
    {ok, Port} = inet:port(S),
    ok = gen_tcp:close(S),
    Port.

put_address(I, Octets) ->
    put_buffer(I, byte_size(Octets)),
    ok = wasm:write_memory(I, 48, Octets).

put_buffer(I, Size) ->
    ok = wasm:write_memory(I, 32, <<48:32/little, Size:32/little>>).

connected(Config, Net) ->
    I = instance(Config, Net),
    ?assertEqual({ok, [?ESUCCESS]},
                 wasm:call(I, ~"open", [?ADDRESS_FAMILY_INET4, ?SOCK_TYPE_STREAM])),
    {ok, [Fd]} = wasm:call(I, ~"out_fd", []),
    {I, Fd}.

%%% ----------------------------------------------------------------- routes ---

%% An absent capability is refused, not silently granted. Every call, not the
%% ones that were convenient to test: a sweep is the only version of this claim
%% worth making.
no_grant_refuses_every_socket_call(Config) ->
    I = instance(Config, none),
    put_address(I, <<127, 0, 0, 1>>),
    ok = wasm:write_memory(I, 128, <<127, 0, 0, 1>>),
    ok = wasm:write_memory(I, 320, ~"localhost"),
    %% Opening and resolving are refused as capabilities. Everything else needs
    %% a descriptor first, and there is none to be had, so it is refused as a
    %% descriptor. Neither succeeds, which is the property.
    Refused =
        [{~"open", [?ADDRESS_FAMILY_INET4, ?SOCK_TYPE_STREAM], ?ENOTCAPABLE},
         {~"getaddrinfo", [9, 0, 1], ?ENOTCAPABLE},
         {~"bind", [3, 80], ?EBADF},
         {~"listen", [3, 8], ?EBADF},
         {~"connect", [3, 80], ?EBADF},
         {~"accept", [3], ?EBADF},
         {~"send", [3, 1], ?EBADF},
         {~"recv", [3, 1], ?EBADF},
         {~"send_to", [3, 1, 80], ?EBADF},
         {~"recv_from", [3, 1], ?EBADF},
         {~"getlocal", [3], ?EBADF},
         {~"getpeer", [3], ?EBADF},
         {~"getopt", [3, ?SO_TYPE], ?EBADF},
         {~"setopt", [3, ?SO_TYPE], ?EBADF}],
    [?assertEqual({ok, [Want]}, wasm:call(I, Name, Args), Name)
     || {Name, Args, Want} <- Refused].

%% Descriptor numbers are per instance. Handing fd 3 to an instance that was
%% granted something else does not reach the first instance's socket, because
%% the table it indexes is not the same table.
a_descriptor_does_not_cross_instances(Config) ->
    PortA = free_port(),
    A = instance(Config, #{listen => [{tcp, ~"127.0.0.1", PortA}]}),
    put_buffer(A, 16),
    ?assertEqual({ok, [?ESUCCESS]}, wasm:call(A, ~"getlocal", [3])),
    ?assertEqual({ok, [PortA]}, wasm:call(A, ~"port", [])),

    %% A second instance, granted a different port, has its own fd 3.
    PortB = free_port(),
    B = instance(Config, #{listen => [{tcp, ~"127.0.0.1", PortB}]}),
    put_buffer(B, 16),
    ?assertEqual({ok, [?ESUCCESS]}, wasm:call(B, ~"getlocal", [3])),
    ?assertEqual({ok, [PortB]}, wasm:call(B, ~"port", [])),

    %% And an instance granted nothing has no fd 3 at all, however many other
    %% instances do.
    C = instance(Config, none),
    put_buffer(C, 16),
    ?assertEqual({ok, [?EBADF]}, wasm:call(C, ~"getlocal", [3])).

%% The same argument `wasi_path' makes for `ENOTCAPABLE' over `ENOENT'. A
%% refusal that varied with what the host is running would turn the errno into
%% a port scanner.
a_refusal_says_nothing_about_the_host(Config) ->
    Granted = free_port(),
    Quiet = free_port(),
    {I, Fd} = connected(Config, #{connect => [{tcp, ~"127.0.0.1", Granted}]}),
    put_address(I, <<127, 0, 0, 1>>),
    ?assertEqual({ok, [?ENOTCAPABLE]}, wasm:call(I, ~"connect", [Fd, Quiet])),
    %% An address the grant does not name is refused the same way, whether or
    %% not it exists.
    put_address(I, <<192, 0, 2, 1>>),
    ?assertEqual({ok, [?ENOTCAPABLE]}, wasm:call(I, ~"connect", [Fd, Granted])).

an_ungranted_port_is_refused_even_where_something_listens(Config) ->
    Granted = free_port(),
    {ok, L} = gen_tcp:listen(0, [binary, {active, false}, {ip, {127, 0, 0, 1}}]),
    {ok, Listening} = inet:port(L),
    {I, Fd} = connected(Config, #{connect => [{tcp, ~"127.0.0.1", Granted}]}),
    put_address(I, <<127, 0, 0, 1>>),
    %% Something is accepting on this port. The answer is the same one a dead
    %% port gets, and nothing was attempted.
    ?assertEqual({ok, [?ENOTCAPABLE]}, wasm:call(I, ~"connect", [Fd, Listening])),
    ?assertEqual({error, timeout}, gen_tcp:accept(L, 200)),
    ok = gen_tcp:close(L).

%%% ------------------------------------------------- what it does not cover ---

%% `docs/security.md' says there are no implicit denials and that `0.0.0.0/0'
%% therefore includes link-local and cloud metadata addresses. That is a
%% documented sharp edge rather than an oversight, so it is asserted here: if
%% somebody later adds a hidden deny list, this fails and the document gets
%% corrected with it.
a_wildcard_grant_really_is_a_wildcard(_Config) ->
    G = wasi_net:grant(#{connect => [{tcp, ~"0.0.0.0/0", any}]}),
    ?assert(wasi_net:allows(connect, {tcp, {169, 254, 169, 254}, 80}, G)),
    ?assert(wasi_net:allows(connect, {tcp, {127, 0, 0, 1}, 22}, G)),
    ?assert(wasi_net:allows(connect, {tcp, {10, 0, 0, 1}, 80}, G)),
    %% Which is why a grant should name what it means. This one does.
    Narrow = wasi_net:grant(#{connect => [{tcp, ~"93.184.216.0/24", 443}]}),
    ?assertNot(wasi_net:allows(connect, {tcp, {169, 254, 169, 254}, 80}, Narrow)).

%% The route the plan called out: a name is resolved, the answer moves, and the
%% module connects to wherever it landed. It cannot, because the grant names
%% addresses and the check is on the address handed to connect. Resolution
%% happens through a capability of its own and its answers carry no authority.
resolution_cannot_widen_a_grant(Config) ->
    {I, Fd} = connected(Config, #{connect => [{tcp, ~"10.11.12.13", 443}],
                                  resolve => allow}),
    %% Whatever the resolver says, and it is asked for real here.
    ok = wasm:write_memory(I, 320, ~"localhost"),
    ok = wasm:write_memory(I, 352, <<>>),
    ok = wasm:write_memory(I, 288, <<0:(28 * 8)>>),
    Slots = [512, 576],
    ok = wasm:write_memory(I, 160,
                           iolist_to_binary([<<S:32/little>> || S <- Slots])),
    [begin
         ok = wasm:write_memory(I, S, <<0:(28 * 8)>>),
         ok = wasm:write_memory(I, S + 12, <<(S + 32):32/little>>),
         ok = wasm:write_memory(I, S + 32,
                                <<0:8, 0:24, 18:32/little, (S + 48):32/little>>)
     end || S <- Slots],
    ?assertEqual({ok, [?ESUCCESS]}, wasm:call(I, ~"getaddrinfo", [9, 0, 2])),
    {ok, [Count]} = wasm:call(I, ~"count", []),
    ?assert(Count >= 1),
    %% The answer is an address the grant does not name, so connecting to it is
    %% refused exactly as if it had been typed in.
    put_address(I, <<127, 0, 0, 1>>),
    ?assertEqual({ok, [?ENOTCAPABLE]}, wasm:call(I, ~"connect", [Fd, 443])),
    %% And there is no second resolution between the check and the syscall for
    %% an answer to change under: `sock_connect' takes an address, never a name.
    ?assertEqual({ok, [?ENOTCAPABLE]}, wasm:call(I, ~"connect", [Fd, 80])).
