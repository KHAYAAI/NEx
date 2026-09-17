;; A deliberately trivial WebAssembly module for hub/sandbox/sandbox-demo.sh's
;; Wasmtime check. Real WASM bytecode, hand-written rather than compiled from
;; a higher-level language — there's no toolchain available in this
;; environment to compile a real MCP app down to WASM, so this proves
;; Wasmtime itself executes real wasm correctly, not that any specific
;; hub component has been ported to it. See README.md for what this
;; does and doesn't prove about the sandboxing model.
(module
  (func $add (export "add") (param $a i32) (param $b i32) (result i32)
    local.get $a
    local.get $b
    i32.add))
