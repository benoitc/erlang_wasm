%% -*- erlang -*-
%% The node-wide snapshot byte-budget counter is a persistent_term holding an
%% `atomics' ref. `wasm_store' seeds it once, deterministically, so there is no
%% check-then-put race, and `wasm_snapshot_owner' only reads it. The value is
%% tagged with a version so a counter left by an older, racy build is recognised
%% as untrusted rather than metered against.
-ifndef(WASM_SNAPSHOT_BUDGET_HRL).
-define(WASM_SNAPSHOT_BUDGET_HRL, true).

-define(SNAPSHOT_BUDGET_KEY, {wasm_snapshot_owner, charged}).
-define(SNAPSHOT_BUDGET_VERSION, 1).

-endif.
