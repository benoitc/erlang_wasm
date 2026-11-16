# wasmtime's component threading scripts

These are wasmtime's test scripts for the Component Model's cooperative
thread built-ins, `tests/misc_testsuite/component-model-threading/*.wast`,
at the tag `scripts/build-wasmtime-p2.sh` pins. `wasm-tools json-from-wast`
turned each script into a JSON command list and one binary per component.
`wasm_component_wast_SUITE` runs them.

To rebuild them, run `scripts/build-wat-component-fixtures.sh` after
`scripts/build-wasmtime-p2.sh` has cloned wasmtime.

wasmtime is licensed under the Apache License 2.0 with the LLVM exception.
