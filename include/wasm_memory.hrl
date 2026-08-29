%% -*- erlang -*-
%% Where each field of a memory handle lives, for code that reads one directly.
%%
%% Generated code performs a load or a store inline rather than calling into
%% `wasm_memory' for every access, which means indexing the handle. Literals
%% that silently disagreed with the record would read the wrong field and
%% corrupt memory rather than fail, so `wasm_memory:field_indices/0' answers the
%% real ones and `wasm_core_SUITE' asserts the two agree: adding a field to
%% `#mem{}' breaks a test instead of a module.

-ifndef(WASM_MEMORY_HRL).
-define(WASM_MEMORY_HRL, true).

-define(MEM_CHUNKS, 3).
-define(MEM_PAGES, 4).
-define(MEM_PAGES_REF, 5).
-define(MEM_CHUNKS_REF, 6).
-define(MEM_SHIFT, 10).
-define(MEM_SIZE, 11).

-endif.
