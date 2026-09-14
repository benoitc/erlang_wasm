-module(script_v1).
-moduledoc """
The `script_v1` profile: one source, a JSON context, `main(context)`, a JSON
result.

This is a **profile, not the protocol**. The kernel knows none of it: no JSON,
no file staging, no framing convention. A language adapter calls into here to
get the shared half, and the version in the name is what lets a second profile
exist later without breaking this one.

```python
def main(context):
    return {"answer": context["value"] + 1}
```

```javascript
export function main(context) {
    return { answer: context.value + 1 };
}
```

## Two transports, and the second is honestly a combined stream

They are not one mechanism with a fallback. They carry different guarantees,
and an artifact gets one of them, named.

**`script_v1.channel`, for guests we build.** The adapter adds a host import,
`worker.result(ptr, len)`, bound to the kernel's `result` channel. Genuinely
separate: stdout, stderr and result carry independent bounds, all three are
enforced while streaming, and no parsing is involved. It needs control of the
guest's imports.

**`script_v1.combined`, for an artifact whose imports we cannot change** --
exactly the interpreters we fetch. The result arrives **on stdout**, which
means one bound over the stream that is actually shared: `max_combined_bytes`
covers stdout and the result together, because on this transport they are one
descriptor. `stderr` is a separate descriptor and keeps its own
`max_output_bytes`.

## The marker authenticates nothing

A fixed delimiter collides with ordinary tenant output, so the host generates
16 random bytes per request and hex-encodes them (raw bytes are not valid
`argv`: they can contain NUL and invalid encodings). The bootstrap emits
`MARKER ++ JSON ++ "\\n"` as its last write, and `decode_combined/2` reads the
**last** occurrence.

**The tenant can read `argv`, and so the marker.** This transport cannot
distinguish bootstrap output from tenant output imitating it. It makes
accidental collision negligible and does no more. A tenant controls its own
result either way, so nothing is lost that was ever held, but `argv` is not a
boundary and this documentation will not call it one. **Strict framing
guarantees require `script_v1.channel`** and its dedicated `worker.result`
import.

Both transports require the bootstrap to **write its output through rather
than buffer it**. A guest that collects stdout internally and flushes at the
end defeats the streaming bound completely.

## The envelope

A bootstrap frames an **envelope**, never a bare result, because "the tenant
returned something" and "the tenant's code did not run" have to be told apart
and a bare value cannot say which happened:

```json
{"ok": {"answer": 42}}
{"error": {"code": "exception", "message": "name 'x' is not defined"}}
```

`code` is matched against `codes/0` and anything else is `bad_result`. The set
belongs to the profile rather than to the tenant: a guest may put whatever it
likes there, and a host that switched on an unrecognised one would be switching
on tenant input.

## Error codes

The profile's vocabulary, and **binaries rather than atoms**: the atom table is
node-wide and never reclaimed, so a language's own error names must never
reach it. They travel in `ctx.code` under the kernel's `adapter_failure`.

| code | meaning |
| --- | --- |
| `~"no_entry_point"` | the source defines no `main` |
| `~"exception"` | `main` raised |
| `~"bad_result"` | something was framed, and it was not JSON |
| `~"no_result"` | nothing was framed at all |
""".

-export([version/0, marker/0, encode_context/1, decode_combined/2,
         decode_channel/1, error/3, codes/0, combined_limits/1]).

-define(VERSION, ~"script_v1").

-doc "Which profile this is. Recorded against an artifact, and versioned.".
-spec version() -> binary().
version() -> ?VERSION.

-doc """
A fresh delimiter for one request.

Sixteen random bytes, hex-encoded so it survives `argv`. Collision-resistant,
and nothing more than that.
""".
-spec marker() -> binary().
marker() -> binary:encode_hex(crypto:strong_rand_bytes(16), lowercase).

-doc "The context, as the bytes a guest will parse.".
-spec encode_context(term()) -> binary().
encode_context(Context) -> iolist_to_binary(json:encode(Context)).

-doc """
Split a combined stream into the tenant's output and the framed result.

Read from the **last** occurrence, because any byte could be followed by more
until the guest terminates, and because a tenant that prints something
marker-shaped must not be able to truncate its own result by accident.
""".
-spec decode_combined(binary(), binary()) ->
          {ok, #{result := term(), stdout := binary()}}
        | {error, binary(), binary()}.
decode_combined(Stdout, Marker) ->
    case last_split(Stdout, Marker) of
        nomatch ->
            {error, ~"no_result", ~"the guest framed no result"};
        {Before, After} ->
            case json_of(strip_newline(After)) of
                error ->
                    {error, ~"bad_result", ~"the framed result is not JSON"};
                {ok, Json} ->
                    case envelope(Json) of
                        {ok, Result}         -> {ok, #{result => Result,
                                                       stdout => Before}};
                        {error, _, _} = Err  -> Err
                    end
            end
    end.

-doc "Parse what arrived on the dedicated result channel.".
-spec decode_channel(binary()) -> {ok, term()} | {error, binary(), binary()}.
decode_channel(<<>>) ->
    {error, ~"no_result", ~"the guest wrote no result"};
decode_channel(Bytes) ->
    case json_of(strip_newline(Bytes)) of
        error       -> {error, ~"bad_result", ~"the result is not JSON"};
        {ok, Json}  -> envelope(Json)
    end.

-doc """
A profile error, in the kernel's shape.

The kind is always `adapter_failure`, because that set is closed. What varies
is `ctx.code`, which is a binary and can grow with the languages.
""".
-spec error(binary(), binary(), map()) -> worker_error:worker_error().
error(Code, Msg, Ctx) ->
    worker_error:adapter(adapter_failure, Msg, Ctx#{code => Code}).

-doc "Every code this profile defines. Extensible without touching the kernel.".
-spec codes() -> [binary()].
codes() -> [~"no_entry_point", ~"exception", ~"bad_result", ~"no_result"].

-doc """
Apply `max_combined_bytes` to the descriptor that actually carries both.

On the combined transport stdout carries the tenant's output *and* the framed
result, so that is the stream the combined budget belongs to. `stderr` is a
separate descriptor and keeps `max_output_bytes`, and `max_result_bytes` is not
consulted at all, because nothing is written to the result channel.

```erlang
Limits = script_v1:combined_limits(#{max_combined_bytes => 65_536}),
{ok, W} = script_worker:start_link(qjs_adapter, #{limits => Limits, ...}).
```
""".
-spec combined_limits(map()) -> map().
combined_limits(Limits) ->
    Combined = maps:get(max_combined_bytes, Limits, 1_048_576),
    Stderr = case maps:get(max_output_bytes, Limits, 1_048_576) of
                 N when is_integer(N) -> N;
                 #{stderr := M}       -> M
             end,
    Limits#{max_output_bytes => #{stdout => Combined, stderr => Stderr}}.

%%% ----------------------------------------------------------------- guts ---

%% A bare value cannot say whether the tenant returned it or never ran, so the
%% bootstrap frames which of the two happened.
envelope(#{~"ok" := Result}) ->
    {ok, Result};
envelope(#{~"error" := #{~"code" := Code, ~"message" := Msg}})
  when is_binary(Code), is_binary(Msg) ->
    case lists:member(Code, codes()) of
        true ->
            {error, Code, Msg};
        false ->
            %% The code set is the profile's, not the tenant's. A host that
            %% switched on an unrecognised one would be switching on tenant
            %% input, so an unknown code is simply a malformed result.
            {error, ~"bad_result", ~"the result names no known code"}
    end;
envelope(_Other) ->
    {error, ~"bad_result", ~"the result is not a script_v1 envelope"}.

%% The last occurrence, not the first. `binary:matches/2` gives every one, so
%% this is a fold rather than a scan backwards through a binary.
last_split(Bin, Marker) ->
    case binary:matches(Bin, Marker) of
        [] ->
            nomatch;
        Matches ->
            {Start, Len} = lists:last(Matches),
            {binary:part(Bin, 0, Start),
             binary:part(Bin, Start + Len, byte_size(Bin) - Start - Len)}
    end.

strip_newline(Bin) ->
    case binary:last(Bin) of
        $\n -> binary:part(Bin, 0, byte_size(Bin) - 1);
        _   -> Bin
    end.

%% Nothing a guest supplies becomes an atom: `json:decode/1` keeps object keys
%% as binaries, which is the half of the rule that matters here.
json_of(<<>>) ->
    error;
json_of(Bin) ->
    try {ok, json:decode(Bin)}
    catch _:_ -> error
    end.
