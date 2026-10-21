%% -*- erlang -*-
%% The Component Model's section ids, one name each.
%%
%% Three modules walk a component's sections, and each used to define the ids
%% it needed under its own names, so section 4 was both `NESTED_COMPONENT_SEC'
%% and `SEC_COMPONENT' and section 10 both `SEC_COMP_IMPORT' and `SEC_IMPORT'.

-ifndef(WASM_COMPONENT_HRL).
-define(WASM_COMPONENT_HRL, true).

-define(SEC_CORE_MODULE, 1).
-define(SEC_CORE_INSTANCE, 2).
-define(SEC_COMPONENT, 4).
-define(SEC_COMP_INSTANCE, 5).
-define(SEC_ALIAS, 6).
-define(SEC_TYPE, 7).
-define(SEC_CANON, 8).
-define(SEC_COMP_IMPORT, 10).
-define(SEC_EXPORT, 11).

-endif.
