%% -*- erlang -*-
%% An image, `#snapshot{}'. Owned by `wasm_snapshot', which is the only module
%% that builds or reads one, with one exception: `wasm_keeper' reads `live' off
%% a published image whose row it no longer has, at its own start. Calling
%% `wasm_snapshot' from there would put the keeper above the memories that call
%% it, and the module graph's cycles are pinned.
-ifndef(WASM_SNAPSHOT_HRL).
-define(WASM_SNAPSHOT_HRL, true).

%% Deliberately not a map: a snapshot is matched on, and a record gives the
%% compiler something to check when a field is added later.
-record(snapshot, {
          id            :: reference(),
          handle        :: wasm_module_cache:handle(),
          version       :: binary(),
          key           :: term(),
          source        :: reference(),
          globals       :: tuple(),
          %% The **contents**, not the handles. A table is a handle exactly as
          %% a memory is, and capturing `#mut.tables` captured the source
          %% instance's tables: a restored instance then called through a table
          %% that had been freed with the instance it belonged to. Calling
          %% through the table is what caught it; comparing the tuples would
          %% have looked perfectly correct.
          tables        :: [[term()]],
          mems          :: [wasm_snapshot:captured_mem()],
          dropped_elems :: map(),
          dropped_datas :: map(),
          %% What each import module's hook said to keep, by module name.
          hooks         :: #{binary() => wasm_snapshot:portable()},
          bytes         :: non_neg_integer(),
          %% The keeper's record of the image's pages, which every memory
          %% restored from it names, and which keeps them charged for as long
          %% as one of those memories or a holder of the image remains.
          img_res       :: undefined | wasm_keeper:resource(),
          %% The process that holds this image's claim on its module and its
          %% share of the byte budget, and that knows who still wants it. An
          %% image is an Erlang term and the BEAM will collect it, but a term
          %% cannot say "I am gone", and two things have to be given back when
          %% it is.
          owner         :: undefined | pid(),
          %% 1 while new restores of this image are allowed, 0 for ever after:
          %% a one-element `atomics' array its owner makes. Its owner clears it
          %% when the last holder goes, and the keeper does when it sees the
          %% owner go for any reason, so a published image is refused the
          %% moment it stops being restorable. Never written to a file:
          %% `to_parts/1' builds an explicit map, and the default covers an
          %% image read back from one.
          live = undefined :: undefined | atomics:atomics_ref()
         }).

%% Where a shared image is published in `persistent_term', by its generation:
%% the keeper's resource for the image. Only the keeper puts or erases one.
-define(SNAPSHOT_PUB(Generation), {wasm_snapshot, Generation}).

-endif.
