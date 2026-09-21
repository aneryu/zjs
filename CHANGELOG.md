# Changelog

## Unreleased

- **Tests:** retire `src/stress.zig` / `test-stress`. The unique cheap
  pins (raw tail-opcode budget restore, padded-arg abrupt teardown,
  `subMulAt` pattern sweep, concise-arrow `tail_call` fold) live in
  `tests/exec.zig` and `src/libs/bigint.zig`. Deep default-budget
  unwind and the 500k random limb sweep were repeating the eval-tail
  walker and the division identity tests. `check`, batch-gate,
  production-gate, and CI no longer compile a third test root.
- **CLI:** move the test262 `$262` host back under `run-test262`.
  `src/cli/run_test262_host.zig` is a `test262_host` module that depends
  on the engine; `src/root.zig` no longer exports it. Test compiles add
  the same module so `TestEngine` can still install harness globals.
  The CLI imports the host file directly to retain its colocated tests.
- **Tests:** the shared harness is integration-test infrastructure.
  It lives at `tests/harness.zig` plus `tests/harness/` (`gc`, `expect`,
  `fixture`, `test_engine`, `shared`) and imports the engine as `zjs`.
  `src/root.zig` no longer exports `zjs.testing`. Parser/bytecode unit
  tests reclaim with a local `runObjectCycleRemoval` helper.
- **CLI:** drop the ReleaseFast `simple_panic` override
  (`src/cli/panic_policy.zig`). Both binaries use Zig's default handler
  in every optimize mode.
- **CLI:** files default to module. `zjs file.js` no longer sniffs the
  first token or the `.mjs` suffix (the qjs `JS_DetectModule` clone is
  gone). `-e` stays script; `-s` forces script; `-m` still names module
  explicitly. `-I` includes are modules. The external test262 engine
  path passes `-s` for script tests.
- **CLI:** `zjs` argv parsing is a pure slice → `Command` layer in
  `src/cli/zjs.zig`. `-e` is a file whose source is already filled;
  options live in one table. `--name=value` and `--` are accepted. `main`
  only parses, then `execute`s.
- **Tests:** split Zig tests into unit vs integration. Unit tests stay
  next to the implementation (colocated `test` blocks plus
  `src/parser/tests.zig`, `src/compiler/tests.zig`,
  `src/bytecode/tests.zig`). Multi-module system tests moved to
  `tests/core.zig`, `tests/exec.zig`, and `tests/public_api.zig`, pulled
  by `test_root.zig` via `tests/engine.zig` when
  `zjs_unified_test_suite` is on. The same root file-imports the
  parser/compiler/bytecode unit suites so `--test-filter` can see them.
  Zig 0.16 names the integration tests `tests.public_api.`, `tests.core.`,
  `tests.exec.`. `test-leak-census` filters `tests.exec.`.
- **CLI / build:** removed `--perf-json`, the in-tree `perf-benchmark` step,
  and `tests/perf/microbench.js`. Repeatable timing lives outside this
  repository. `--profile-opcodes` still prints the human-readable opcode
  table; smoke reads `opcodes executed:` from that stdout dump.
- **Build:** `src/internal_root.zig` and `src/unified_tests.zig` are gone.
  `src/root.zig` is the single engine module (`@import("zjs")` is itself).
  The engine Zig-test root is `test_root.zig` so one module can see both
  `src/` unit tests and `tests/` integration tests. CLI tests compile from
  `src/cli/tests.zig` against `src/root.zig`. The separate stress root
  and `test-stress` step are retired as described above.
  `ZJS_RUN_STRESS` / `skipUnlessStress` are gone. Embedder names stay
  `Runtime` / `Context` / `Value` / `Call` / `EventLoop`; JS* names and
  layer re-exports live on the same module. There is no `public_api` alias.
- **Public API:** the embedder surface is now ownership-named. `src/root.zig`
  exports `Runtime`, `Context`, `Value`, `Call`, and `EventLoop`. Nested
  option types live on their owner (`Runtime.Options`, `Context.EvalMode` /
  `EvalOptions` / `FunctionOptions`). `Context.defineFunction` takes
  `fn (*Call) E!Value` directly; `Context.defineScriptArgs` installs the CLI
  `scriptArgs` global; `Context.globalObject` returns a `Value`. Removed the
  `zjs.host` / `zjs.context` wrapper namespaces. `zjs.native` and
  `zjs.runtime` remain engine-layer exports, and `JSRuntime` / `JSContext` /
  `JSValue` remain aliases on the same module. `CallSite`, `PropertySite`,
  and `NativeBinding` stay deleted. Handles come from `Runtime` methods;
  byte stores from `Value.Bytes.Store`.
- **Public API (prior):** `src/root.zig` was the CLI / `run-test262` host facade, not
  a second object model. Removed `zjs.value` (constructors and handle
  aliases), `zjs.object` (opaque Object, Buffer borrows), `zjs.module`,
  `zjs.job`, `host.defineArgvGlobals`, and `host.evalGlobalScript*`. Kept
  opcode-profile helpers. Handles come from `Runtime` methods; byte
  stores from `Value.Bytes.Store`.
- **Build (prior):** restored CLI compilation after 617e6941 imported the CLI and
  stress test families from `src/internal_root.zig` behind a comptime `if`;
  Zig assigns files to modules when it collects imports, so `zig build zjs`
  failed with a module clash in every optimize mode. `src/unified_tests.zig`
  became the unified test root (mirroring `internal_root`, comptime
  checked), and `src/cli/run_test262_host.zig` moved into the engine tree as
  `src/test262_host.zig` (shared by `run-test262` and the test helpers), and
  engine files stopped importing `src/cli/` or `src/stress.zig`. The root
  and host layout described above supersedes that intermediate arrangement.
  `tools/gates/bytecode_fingerprint.sh` is back as the identity gate.
- **Bytecode:** the call-site cache is gone. Every variable-arity call
  instruction carried a trailing `cache_idx:u8` into a `call_sites` FAM tail
  of `CallSiteCache` slots (24 bytes each, allocated, zeroed and freed with
  every FunctionBytecode) that no handler ever read: dispatch skipped the
  byte. `call` / `tail_call` / `call_method` / `tail_call_method` /
  `call_method_apply_fwd` are plain `npop` (`argc:u16`) again and `call0..3`
  are one byte (`none_npop`); `Format.npop_u8` / `npopx`, `CallSiteCache`,
  `FunctionLayout.call_sites_off`, the hot extension's `call_sites` pointer
  and count (the extension is 56 bytes, was 64), `Bytecode.call_site_count`,
  `Builder.emitCallOp` and the resolver's site allocator are deleted. This
  changes the final bytecode of every function with a call, so the
  fingerprint corpus moves by design; test262 is the identity check.
- **Exec:** the dispatch table proves its own cover at compile time: every
  id the physical ledger marks `claimed` must have a handler that is not the
  `op_invalid` trap, and no unclaimed id may have one.
- **Bytecode:** the hand-written inline/forward policy reject lists that
  `traitsOf` had to reproduce form for form are deleted; the declaration is
  the only copy.
- **Bytecode/Exec:** `FunctionBytecode` is the only executable artifact.
  The stack-only `LegacyExecutionAdapter` that let a mutable compile-time
  `Bytecode` masquerade as a `FunctionBytecode` (negative `byte_code_len`
  sentinel, pointer slot after the hot extension) is deleted, and with it
  every `legacyBytecodeAdapter()` branch in the FB accessors (`byteCode`,
  `cpoolSlice`, `closureVar`, `varRef*`, `entryContract`, `pc2lineBuf`,
  `lineNum`/`colNum`, `sourceText`, `scriptOrModule`, `realmContext`,
  `isGlobalVar`), the exec gates that tested for it (`zjs_vm.run`,
  `runWithArgs`, `runWithArgsState`, `vm_call.initFrameVarRefs`,
  `vm_property`, `call_runtime`), the frame-entry cell reconstruction that
  only the adapter reached (`legacyInitialClosureVarRef`, the
  `var_ref_names` arm), the runtime global-declaration instantiation it
  alone triggered (`instantiateGlobalVarDeclarationCells`,
  `defineGlobalDeclVarCell`, `CallEnv.global_declarations_prevalidated`),
  and the `Bytecode.var_ref_names` mirror plus its `varRef*` accessors.
  Tests that executed hand-written bytecode now build a real published
  fixture through `testing.makeFixture` / `runFixture` (over
  `FunctionBytecode.createFixture`), frame tests use unpublished fixtures,
  and the two `vm_helpers` fragment runners finalize through
  `createFunctionBytecode`. Three tests that pinned adapter-only behaviour
  (synthetic var-ref name mirrors, adapter layout, one-slot-at-a-time
  global declaration rebinding) are gone with the mechanism.
- **API (breaking):** `JSRuntime.create(allocator, options)` and
  `JSContext.create(rt, options)` take their options directly; the
  `createWithOptions` pair is deleted (`createWithOptionsMeasured` is
  `createMeasured`). Pass `.{}` for the defaults. README, the embedding
  cookbook, the public-API contract, `tests/embedding_examples.zig`,
  `tests/oom.zig` and every unit test are updated.
- **CLI:** `zjs` no longer wraps `Runtime` / `Context` / `EventLoop` in a
  local bundle type. `execute` keeps those three as locals; `--leak-check`
  tears down the event loop, context, then runtime.
- **CLI:** `zjs` `main` is decomposed into `loadSource` / `configureRuntime`
  / `evalSource` / `failEvaluation` (`!noreturn`) / `exitIfRequested`.
  Argv lives in `src/cli/zjs.zig`. `-e` is a file whose source is already
  filled and whose mode stays script; a path leaves `source` null until
  `loadSource` reads it, preserving the mode selected by argv parsing. Later
  stages do not switch on how the job was filled. The fabricated
  `TypeError: not a function ... :7:20` stack printed for an exception-less
  `error.TypeError` is gone; that path now reports
  `zjs: evaluation failed: TypeError` like every other bare error.
- **Parser:** the parse root no longer needs a `Bytecode` carrier. `State`
  carries `memory` / `atoms` / `root_name` and owns the module record
  (`ensureModule`, `takeModuleRecord`); `State.init(lex, memory, atoms, name)`
  and `initWithRuntime(rt, lex, name)` replace the carrier-taking
  constructors (`initCanonicalRootWithRuntime` is gone), `State.deinit`
  takes a `*JSRuntime`. `parser.compile` builds no carrier: the root
  flags it used to publish on one were never read, and the module record
  moves straight from the State to the module artifact. `Bytecode` is now
  purely the finalize staging record (`module_record` / `ensureModule`
  deleted). Bytecode fingerprint identical.
- **Bytecode/Compiler:** `src/bytecode.zig` (11.1k lines) is split by
  namespace into files; the hub keeps the import surface (`bytecode.opcode`,
  `bytecode.pipeline.{pc2line,stack_size,finalize}`, `bytecode.module`,
  `bytecode.dump`, `bytecode.function_def`, `bytecode.function_bytecode`,
  `bytecode.carrier`) and the compile policy/context types.
  `bytecode/opcode.zig`, `function_def.zig`, `carrier.zig` (the `Bytecode`
  parse-root / staging record, formerly the private `function_mod`),
  `function_bytecode.zig`, `module.zig`, `pc2line.zig`, `dump.zig` sit under
  `src/bytecode/`; `binding_rules.zig`, `stack_size.zig`, `finalize.zig`
  under `src/compiler/`. The `pipeline_pc2line` / `pipeline_stack_size` /
  `pipeline_finalize` spellings are gone (`bytecode.pipeline.*` was already
  the public path). Pure move: bytecode fingerprint identical.
- **Compiler/Bytecode:** the non-packed lowering path is gone. Production
  always finalized through `createFunctionBytecode`; a second entry
  (`runWithFunctionDef` / `runWithFunctionDefRuntime` /
  `lowerAttachedBuilder`) lowered into the mutable `Bytecode` carrier for
  test fixtures only, copying the FunctionDef pool into a mirror
  `Bytecode.constants` (a reserved BigInt then had two owners) and
  publishing `vardefs` / `argdefs` / `closure_var` mirrors nothing executed.
  Deleted: those entries, `syncFunctionDefCpool`, `syncBytecode{VarNames,
  ArgDefs,ClosureVars}`, `publishLoweredMetadata`'s comptime variants,
  `constant.Pool`, the `Bytecode` mirror fields and their accessors
  (`argVarDefs`, `varDefs`, `closureVar`, `cpoolSlice`, `constantAt`,
  `addConstant`, `traceCompileRoots`), the root-carrier streaming API
  (`appendAtomOperand`, `appendSourceLoc`, `truncateSourceLocs`),
  `codeMaterializesArgumentsObject`, `compiler.compileFunctionForPackedFinalize`
  (`compileFunction` is the packed entry), `resolve_labels.run{Impl,
  ForPackedFinalize}` with the duplicate `validateProductCode` /
  `validateFinalOutput` walks. `Bytecode.deinit` takes no runtime. Parser
  tests inspect the published `FunctionBytecode` through a `Lowered` view
  (final code, cpool, closure rows, atom operands, module record) and the
  phase-1 tests through a `Raw` view over the live Builder, so the
  ownership ledger samples the artifact the VM runs. Three module export
  tests that relied on the old path skipping local-export resolution now
  declare the bindings they export.
- **Parser:** the test-only `RootMode.raw_bytecode` root is retired with
  it: `State.root_mode`, `emit_to_function_def`, the emission snapshots
  (`EmissionSnapshot`, `takeEmissionSnapshot`, `rollbackEmission`, the
  label-count / code-len / atom-len probes), `ParameterListState.capture_child`
  and the `FunctionDef` byte-stream mirror fields (`byte_code`,
  `atom_operands`, `label_slots`, `jump_slots`, `source_loc_slots` and
  their append/truncate helpers) are deleted; the root is always a
  `FunctionDef` with an attached Builder, constants always go to the
  FunctionDef pool, and `this` / `new.target` / `super` are always scope
  lookups.
- **Compiler:** the Debug/ReleaseSafe exact-CFG oracle is retired.
  `src/compiler/cfg.zig` (3.8k lines, 64% oracle) becomes
  `src/compiler/temp_stream.zig` (the bind-index row, the phase-1 instruction
  view, `SourcePoint`). Gone with it: `cfg.build`, `auditInstructionOwnership`,
  `auditBoundaryUniqueness`, the anchor-split and fan-out censuses and their
  `ZJS_V2_*` reports, `formatOracleReport`, the resolver's per-fold boundary
  records, `markReachableEvalCaptures`, the audit-only `oracle_plan`
  parameters, `binding_rules.planScopeVarAction` / `planScopeVarLowering`
  (an oracle that re-derived the production plan), `resolve_labels`'
  canonical-identity audit and `shortSlotOp` self-check, and the Builder's
  control index (`ControlSlot`, `recordControl`, `enableControlIndex`) that
  only the CFG read. Liveness is QuickJS `update_label` bookkeeping in every
  build mode; three resolver unit tests that had pinned the audit-only
  answer now pin the shipped one. Bytecode fingerprint identical over the
  54k-file corpus.

- **Tests:** Zig unit tests sit in package `tests.zig` files pulled from
  the package root (`src/core/tests.zig`, `src/exec/tests.zig`,
  `src/parser/tests.zig`, `src/bytecode/tests.zig`, matching
  `src/compiler/tests.zig`), plus colocated `test` blocks. Shared harness
  is `src/testing.zig`. Deleted `src/all_tests.zig` and `src/tests/`;
  embedding / smoke / OOM-injection live under `tests/`. Unified suite
  root is `src/internal_root.zig`.

- **Tests:** `zig build test` uses Zig's default test runner (no custom
  sharding runner). `test-fast` is a compile-time `--test-filter`. Stress
  tests in `src/stress.zig` `SkipZigTest` unless `ZJS_RUN_STRESS=1`;
  `test-stress` is a filtered compile of the same root. `test-leak-census`
  keeps a small dedicated two-pass runner (`tools/leak_census_runner.zig`).
  Deleted `tools/timing_test_runner.zig`.

- **Tools:** removed `tools/gates/bytecode_fingerprint.sh`. Parser/compiler
  identity checks stay on `zjs --bytecode-fingerprint` against two binaries.

- **Compiler/Parser:** the legacy emitter mode is retired. `ParseState`
  no longer has `emit_phase1_temp`: the parser always emits the phase-1
  temp stream (`enter_scope` / `leave_scope` markers, `scope_get_var` /
  `scope_put_var` families, wide `fclosure`) and leaves closure capture
  to `resolve_variables`. Deleted with it: `ensureClosureVar` and the
  whole parse-time parent walk (`ensureClosureChain`,
  `findVisibleParentVarCapturingWith`, `ensureArrowSpecialCapture`,
  `ensureImplicitArgumentsLocal`, the global closure-var index),
  `emitGlobalVarOp[NoSource]`, `emitFClosure8`, and the
  `test_entry.Options.emit_phase1_temp` knob. `closure.zig` keeps only
  the read-only visibility queries. The `ParseHarness` expectations in
  `compiler/tests.zig` (62 tests) now assert the canonical stream the
  production parser emits. Bytecode fingerprint identical over 54k files.
- **Compiler/Parser:** `FunctionDef`'s "index or none" fields are
  optionals instead of `i32` with `-1`: the demand-created locals
  (`this_var_idx`, `new_target_var_idx`, `this_active_func_var_idx`,
  `home_object_var_idx`, `func_var_idx`, `arguments_var_idx`,
  `arguments_arg_idx`, `var_object_idx`, `arg_var_object_idx`) are `?u16`
  and the `ensure*Binding` helpers return `u16`; a child's
  `parent_cpool_idx` is `?u16`; `VarDef.func_pool_idx` is `?u32`. The
  write-only `FunctionDef.eval_ret_idx` is gone. The QuickJS scope-chain
  sentinels (`scope_next`, `scope_first`, `body_scope`, `scopes[].first`)
  keep their `-1` / `ARG_SCOPE_END` encoding because the finalized
  bytecode format shares it.

- **Parser:** the parse root's mode is explicit: `State.root_mode` is
  `.canonical` (production: the root is a `FunctionDef`, every function is
  a child, constants go to the FunctionDef pool) or `.raw_bytecode` (the
  parser-level test tier that emits into the root `Bytecode` carrier and
  inlines top-level function bodies). It replaces the
  `top_level_functions_as_children` context flag, which also silently
  chose the constant pool.

- **Parser:** `State` is no longer the home of declaration bookkeeping and
  closure capture: `defineVar` and the `define_var` / `add_scope_var` /
  `add_var` rules, the lexical and function-scope lookups and the
  declaration-conflict index moved to `src/parser/declarations.zig`;
  `ensureClosureVar` and the demand-created special locals moved to
  `src/parser/closure.zig` (whose parent-walk half only runs for the
  legacy emitter used by the compiler test harness). Callers spell
  `declarations.defineVar(s, ...)`; `State.ScopeVarOptions` /
  `DefineVarType` / `DefinedVar` remain as aliases. `parse_state.zig`
  drops from 3503 to about 2230 lines and `State` from 166 to 121 methods.

- **Compiler:** the flat `find_var` pass that follows a lexical-chain miss
  (`resolve_variables`, the parent walk in `resolveBindingTopologyAfterCurrentMiss`)
  no longer scans every var of the function per reference: `FunctionDef`
  keeps a lazily built newest-scope-0-row-per-name index (`findFunctionVar`,
  the role of qjs `var_htab`) once a function has 32 or more vars. Pinned
  to one core, compiling babylon / typescript / babel bundles takes 12%,
  11% and 10% fewer cycles; bytecode is byte-identical.

- **Parser:** the largest grammar functions are split into named steps
  with no bytecode change: `parseFunctionParamsAndBody` (533 lines) is now
  a 30-line sequence over `childFunctionContext` / `createChildFunction` /
  `planFunctionDeclaration` / `parseFunctionHead` /
  `parseFunctionBodyAndCheck` / `finishChildFunction`, with the implicit
  terminating return shared with arrows (`emitFallthroughReturn`);
  `parseExport` dispatches to one function per export form and the four
  function/class arms share `parseExportedFunction` / `parseExportedClass`;
  `parseUnary` hands prefix update, `yield` and `await` to their own
  functions; `parseClassElement` is modifiers → method prefix → accessor /
  private / computed / named element / static block. Small folds: class
  field initializers no longer branch on `static`, `peekNextKind` is
  `peekNext().kind`, `PeekedToken.isBefore` replaces
  `peekNextKindNoLineTerminator`.

- **Parser:** the eight class-scoped `State` fields (`in_class`,
  `class_has_extends`, `is_static`, `class_constructor_cpool_idx`, the
  fields/static-init child indices and the private-brand flags) are one
  `State.class: ClassContext` value that `parseClass` saves, replaces with
  a fresh one and restores as a whole, the same shape as `State.ctx`.

- **Parser:** speculative scans take the next token as a return value
  (`s.lex.next()`) instead of a `var t: Token = undefined` out-parameter
  (30 sites); parse time over the 153 MB jetstream3 corpus is unchanged.
  `nextInto` stays for the parser's own token slot.

- **Parser:** `BlockEnv` says what it means: `has_break_target` /
  `has_continue_target` bools replace the `label_break` / `label_cont`
  0-or-minus-one ints that were only ever tested for sign, `label_name` is
  `?Atom` instead of a `null_atom` sentinel, and the write-only
  `label_finally` field is gone. `State.eval_ret_idx` is `?u16` instead of
  an `i32` with `-1` meaning "not eval".

- **Parser:** the parser error set is a superset of the Builder's
  (`InvalidBytecode` joined `ParserInvariant` on the internal-compiler-error
  arm), so the 67 `catch |err| return mapBuilderError(err)` sites are plain
  `try` and the mapper is gone. The 42 `catch return error.OutOfMemory`
  sites that rewrote every callee error into OOM are `try` as well; the
  three callees with wider error sets (fresh template arrays, base-10
  BigInt formatting) map their impossible arms to `ParserInvariant`
  explicitly instead of to OOM.

- **Parser:** `ParseFunctionKind` answers its own questions (`isAsync`,
  `isGenerator`, `isConstructor`, `isFunctionKeywordForm`, `hasHomeObject`,
  `hasPrototype`, `bytecodeKind`, `withGenerator`) instead of repeated
  two-term comparisons and per-site switches. The unused
  `parser.Parser.FunctionKind` mirror enum is removed; the bytecode
  `FunctionKind` is the only one.

- **Parser:** the "bool flag + `errdefer`" pairs became guard values that
  know whether they are still open: `State.openScope()` / `OpenScope`,
  `emitter.ProtectedRegion` (try block / catch body), `OpenUsingBlock`
  (explicit-resource-management frames), `ChildFunction` (child
  `FunctionDef` hand-off in `parseFunctionParamsAndBody` /
  `parseArrowFunction`), an idempotent `leaveControlBoundary`; control
  blocks use a plain `defer popControlBlock`. Bytecode is byte-identical
  over the fingerprint corpus.

- **Parser:** the function-scoped grammar flags (`in_async`, `in_generator`,
  `allow_super`, `new_target_allowed`, `in_class_static_block`, the
  namespace trio, …) live in one `State.ctx: FunctionContext` value that a
  function boundary saves, derives from the function kind and restores as
  a whole; the `pending_function_*` / `parsing_method_params` entry markers
  are a `FunctionEntry` parameter of `parseFunctionParamsAndBody` and the
  comptime-masked `FunctionEntryContext` is gone. Positional `bool`
  parameters became options structs (`ScopeVarOptions`,
  `ControlBlockOptions`, `FieldInitOptions`, `DestructuringOptions`, …) and
  out-parameters became returned structs (`peekNext()`, parameter
  scanning). Bytecode is byte-identical over the fingerprint corpus.

- **Parser:** token kinds are an `enum(i16)` (`parser.token.Kind`) instead
  of bare `i16` `TOK_*` constants; the QuickJS numbering is unchanged.
  Keywords are `.kw_<name>`, punctuators are named (`.lparen`, `.assign`,
  `.semicolon`, …), and `isPunct` / `expectPunct` are gone in favour of
  `peekKind() == .x` / `expectToken(.x)`. Embedders that spelled
  `parser.token.TOK_EOF` use `parser.token.Kind.eof`.

- **Parser:** `src/parser.zig` is split into `src/parser/` modules
  (`parse_state`, `identifiers`, `lookahead`, `emitter`, `expressions`,
  `statements`, `functions`, `classes`, `modules`, `typescript`); the root
  keeps the token table, lexer, `compile`, and the `Parser` re-exports, so
  `parser.compile` / `parser.Parser.<name>` spellings are unchanged. Same
  day: the emitter facade, boilerplate, and duplicated function/arrow/class
  paths were consolidated (about 560 lines). Bytecode is byte-identical
  over the fingerprint corpus for all of it.

- **Parser:** TypeScript is the grammar; JavaScript is parsed as its subset.
  The lexer-side type-range eraser (`enableTypeScript`, `SourceKind`,
  `findUnsupportedTypeScriptSyntax`) is gone; type syntax is consumed by an
  emission-free type parser inside `parser.zig`, so JavaScript input yields
  byte-identical bytecode (checked with `zjs --bytecode-fingerprint` over
  test262 + jetstream3). Newly accepted: modifiers after any member, `for`/
  `catch` annotations, abstract / optional / overload signatures, `this`
  parameters, angle-bracket assertions, generic calls and instantiation
  expressions, `satisfies`, template literal / mapped / conditional /
  `infer` types, `declare` declarations, `import type` / `export type`,
  `import x = A.B`, enum constant folding (`1 << 2`, `A | B`, `"a" + "b"`)
  with runtime fallback, `module X {}`. Rejected with a message: decorators,
  `import x = require()`, `export =`, `.tsx` / `.jsx`, `accessor`. Public
  API: `parser.Options.source_kind`, `parser.SourceKind`,
  `core.context.EvalSourceKind`, and `ContextEvalOptions.source_kind` are
  removed; drop the field. Known grammar divergence from JavaScript, resolved
  the tsc way: `f<T>(x)` is a generic call and `<T>x` a type assertion.
  test262 `staging/sm/syntax/class-error.js` (`class X { x: 1 }`) is now a
  valid field annotation and is excluded. Namespace fixes that came with it:
  `namespace N { export function f() {} }` now attaches `f` (it never did),
  a namespace body is a real block scope (sibling namespaces may export the
  same names, `var` inside lowers to `let` as in tsc's IIFE), and `enum` /
  `namespace` bindings are `var` (`let` inside a namespace) so `export enum`
  / `export namespace` link in modules. Diagnostics: `@` reports "decorators
  are not supported"; a lexer error inside a class body (for example an
  escaped `#name`) is reported at that token instead of the class brace.

- **Build:** every artifact follows `-Doptimize` (Zig default: Debug).
  `zjs` is no longer pinned to ReleaseFast; `zjs-dev` / `run-test262-dev` /
  `smoke-dev` are gone. Ship with `zig build -Doptimize=ReleaseFast`.
  Batch and production gates that need the shipped binary pass that flag
  explicitly.

- **Build:** removed `src/config_signature.zig` and `src/dossier_pad.zig`.
  The signature lock existed for a mixed Debug/ReleaseFast graph; the pad
  emitted nothing at the default of 0. `--print-config-signature`,
  `config-signature-check`, and `-Dzjs_dossier_layout_pad` are gone.

- **Build:** configuration signature is `zjs-config-v4`. The constant
  `compiler=v2` field is gone; there is one compiler and nothing to select.
  Production names follow that: `FunctionDef.builder`, `compileFunction`,
  and the parse/exec test harnesses no longer carry a `v2` identity.

- **Host surface:** removed the `src/binding/` directory. The host `JSContext`
  facade is `src/js_context.zig`; `zjs.native.managed` is `src/native.zig`.
  Re-exports live on `src/root.zig` and `src/internal_root.zig`. The public
  `zjs.JSContext` / `zjs.native` spellings are unchanged.

- **Numbers:** `libs/number_format` now converts in both directions with
  one kernel each: `floatToText` (dtoa.c `js_dtoa`) and `textToFloat`
  (`js_atod` with the `js_atof` scan rules folded in), exposed as
  `parseNumberPrefix` / `parseNumberExact` with `ParseFlags`. ToNumber,
  parseInt, parseFloat, source literals, JSON and the array-length / typed
  array index paths all go through it; `std.fmt.parseFloat` is gone from
  the engine. `textToFloat` gained a decimal fast path (u64 digits + SWAR,
  Clinger, Eisel-Lemire, bignum fallback) and radix-10 shortest formatting
  uses Ryu, both with comptime-generated tables. Fixes: plain `0…` literals
  hit a missing `no_prefix` branch in the port; parseInt beyond 128 bits in
  a non-power-of-two radix rounded per digit; BigInt → Number now rounds
  once from the limbs (`BigInt.toFloat64`). Powers of two print the
  genuinely shortest string (`2**-1017` → `7.120236347223045e-307`, as V8
  does; QuickJS prints one digit more).

- **Build:** trimmed `build/` after the profiles/perf-harness cut. `Ctx` and
  `Artifacts` keep only fields a helper reads; CLI / shard / smoke setup share
  helpers; `runArtifactOnCpus` lives next to `gateRunCpus` so tests no longer
  import gates.

- **Tools:** removed `gate-smoke` (`tools/gates/`, the `/tmp/gcgap-fixed`
  corpus convention, and the `merge-gate` aggregate). Local
  `mise run batch-gate` is now `checkpoint-gate` + `test-stress` +
  `test262-check`, the same set CI linux-arm64 already runs.

- **Tools:** removed the shared-host watch/timeline helpers
  (`tools/gates/watch.py`, `timeline.py`, and the hand-run meta-tests).
  Use `zig build --watch` locally if a resident incremental rebuild is
  useful. mise no longer wraps `flock` / `taskset`; Run steps stay
  unpinned unless `-Dgate-run-cpus` (or the matching env) is set.

- **Tools:** removed the roadmap renderer/linter (`tools/docs`) and the
  `roadmap-lint` CI job. `docs/roadmap/work-items.yaml` stays as a
  hand-maintained registry; the ID/DAG/status blocks in `docs/roadmap.md`
  are static snapshots.

- **Tools:** removed `tools/perf` (campaign trees, diagnostic harnesses,
  and the vendored bench-v8 / Octane suite). `zig build perf-bench-v8`
  is gone. Local timing stays on `zig build perf-benchmark`
  (`tests/perf/microbench.js`). The last Octane snapshot remains
  `docs/perf/bench-v8-status.md`. Also removed `tools/compare`,
  runtime-profile runners, `macro-check` / `check_completes.py`, and
  advisory scanners (`tools/lint`, `dead_decls.py`,
  `lint_anti_goals.sh`, `codex_run.sh`). Remaining instrument after
  that cut: the test runner.

- **Policy:** retired the measurement and ablation policy (Stage 0,
  size-screen, `measure_fields` field locks, mandatory PMU ABBA, and
  refactor-policy rule 2's bench-v8 A/B / identity-set protocol).
  Correctness stays on `zig build test` and the merge batch. Local
  `perf-benchmark` / `perf stat` are diagnostic only. Removed the
  preregistered `policies/` threshold files (GC merge gate and the
  four spike / opcode-E1 records); recover them from git history.

- **Host surface:** removed the leftover `src/runtime/` directory. The host
  event loop is `src/event_loop.zig`; `zjs.runtime` still exposes
  `EventLoop` / `runUntilIdle`. Timer, rw, and signal lists share one
  growable `HostList`.

- **Host surface:** removed embedder-only binding APIs that CLI and
  test262 do not use: `zjs.PropertySite`, `zjs.host.PropName` /
  `PropNameID`, `zjs.host.NativeBinding` (`src/binding/binding.zig`),
  `zjs.native.leaf` / `leafWithState` / `Class`, `JSContext.defineClass`,
  and the binding-layer `CallSite` wrapper. Host functions stay on
  `zjs.native.managed`. Repeated native → JS calls use
  `JSContext.callFunction`; property IC remains VM-only
  (`exec/call_site.zig`, `PropSiteCache`).

- **Public API:** `zjs.runtime` is the host event loop only (`EventLoop`,
  `runUntilIdle`). Removed exec re-exports: `cleanupAtomicsWaitersForContext`,
  `wakeAtomicsWaitersForRuntimes`, `detachArrayBuffer`,
  `evalFileModuleGraphWithOutput`, `resolveModuleSpecifier`. Call
  `JSContext.destroy` / `src/exec/atomics_ops.zig`,
  `src/exec/buffer_ops.detachArrayBuffer`, `zjs.module`, or
  `src/exec/module_graph.zig` instead. `src/runtime/public.zig` is gone;
  `src/runtime/root.zig` is the single facade.

- **BigInt:** `/` and `%` skip a leading quotient digit that is already known to be zero.

- **Promises:** built-in Promise objects and their state share one allocation; custom class payload ownership is preserved.

- **GC:** initialized dense-array writes shade their exact new targets; buffer adoption and literal fills retain explicit storage/value barriers without rescanning the whole array on each append.

- **Async functions:** fulfilled awaits queue their continuation and value directly, avoiding internal callback and reaction allocations while preserving PromiseResolve observations and asynchronous job ordering.

- **Property caches:** field reads retain two own-property layouts without repeated recapture, using the existing cache storage.

- **GC:** adopting a Shape during incremental marking traces its prototype and
  property keys directly, avoiding repeated scans of the owning array.

- **Promise reactions:** same-realm intrinsic `then` capabilities hold their
  result Promise directly. Species observations, custom constructors, FIFO
  ordering and allocation-failure recovery retain their existing behavior.

- **Async functions:** functions proven unable to suspend can execute in the
  caller's VM with an independently rooted result Promise. Suspension, eval,
  wrappers and observable interrupt cadence retain the existing entry path.

- **Async functions:** result settlement calls the shared Promise resolution
  operation directly, avoiding temporary resolver functions and their unexposed
  once-state allocation. Public resolver once guards, thenable jobs, error realms
  and interrupt accounting are preserved.

- **Promise reactions:** internal reaction records use a dedicated four-slot
  payload, reducing allocation and tracing work while retaining job ordering
  and resolving-function behavior.

- **Async functions:** internal await handlers store their continuation directly
  in the callback object, avoiding generic native-function metadata and payload
  allocations. Thenable resolving functions retain their observable metadata.

- **Property caches:** slots above index 65,535 use the ordinary property
  path, preventing truncated indices from reading or overwriting another
  property. Covers VM and host `PropertySite` reads, writes and native getters.

- **Public API: the host function surface is replaced by `zjs.native`**
  (2026-09-06, native-boundary redesign phase A3, owner rulings D4/D8, hard
  cut without adapters). Removed: `JSContext.defineGlobalFunction` /
  `createExternalFunction`, `zjs.host.Call` / `Function` / `Finalizer` /
  `FunctionOptions`, the `zjs.ffi` plugin ABI, `zjs.runtime.Plugin` /
  `PluginInstallOptions`, the `src/runtime/plugin.zig` loader and
  `docs/runtime-plugin-abi.md`. Added: `zjs.native.managed` / `leaf` /
  `leafWithState` (comptime thunks over a plain Zig function, dispatched
  like builtins through one immutable `NativeEntry`), `zjs.native.Call` /
  `Spec` / `Options` (`length`, `state`, `finalize`, `with_prototype`,
  `realm_global`), `JSContext.defineFunction` / `createFunction`, and
  `zjs.CallSite` (resolved-once native -> JS calls; `JSContext.callFunction`
  is the one-shot form). See `docs/public-api-contract.md` and
  `docs/embedding-cookbook.md`.

- **GC: the `-Dzjs_gc` selector and its six always-true comptime gates are
  removed** (TGC S5-a). `-Dzjs_gc=rc` / `=shadow` had been rejected with a
  migration message since 2026-08-29; the option itself, `build_options.zjs_gc`,
  and `gc.trace_stw_enabled` plus its `generation_enabled` /
  `concurrent_enabled` / `block_heap_enabled` / `address_registry_enabled` /
  `space_model_enabled` aliases now go too. Every `if (comptime ...)` gate that
  read them is unconditional code and every `else` arm is deleted. No behaviour
  change: all six constants were `true` in every build that has shipped since
  the tracing collector became the default.

- **GC: the refcounting collector is removed** (2026-08-29). The tracing
  collector is now the only collector. `-Dzjs_gc=rc` and `-Dzjs_gc=shadow`
  are rejected with a migration message; `-Dzjs_experimental_gc` stays as an
  accepted-but-redundant compat alias. Rolling back to refcounting means a
  frozen binary or a checkout before `6e5d7a69`, not a build flag -- see
  `docs/tracing-gc-experimental-rollout.md`. What went: the trial-deletion
  cycle collector, the Stage 1 shadow observer and its `--gc-shadow-check`
  flags, the doubly-linked `BlockHeader`, the `Phase.remove_cycles` window,
  and every `else` arm of a collector branch. What stayed, on purpose: the
  4-byte refcount prefix on flat strings and ropes (the tracer does not scan
  strings, so the count is their liveness), `LifetimeWord.rc` for `.big_int`,
  and Shape/Realm's true refcounts. Full accounting in
  `docs/rc-retirement-2026-08-29.md`.

- **GC: the tracing collector is the production default** (2026-08-29).
  The `gc/tracing` campaign is squashed into main and Stage 7 is executed:
  stop-the-world tracing with generational minors, block heap, parallel STW
  marking, budgeted lazy destruction, and conservative stack scanning
  replaces refcounting as the default collector. (Refcounting was the
  supported rollback for the length of that same day; see the entry above.)
  Gate basis: gc_heavy_six fixed-work geomean 1.0419 vs the frozen rc
  baseline (margin 1.05), splay major pause p99 ~1ms vs rc 42.4ms,
  test262 0/49778 on the trace build. (Pause row re-anchored 2026-08-29
  under the corrected instrument: splay major p99 1.013 ms vs rc 44.73 ms;
  the gate-basis figures above are left as recorded. See
  `docs/pause-baseline-2026-08-29.md`.) Memory pacing uses growth factor 2.0
  (JSC parity); expect higher transient peak RSS than rc on GC-heavy
  workloads (about +10-13% vs the 1.75 pacing on the six-benchmark corpus).

Target **0.2.0-dev** (unpublished). Maintainability campaign (2026-08-18):
breaking public-API cleanup is approved for this cycle; hot-path structural
refactors are deferred to `docs/backlog.md` and land only under the
refactor-policy gates.

- **Iteration-efficiency overhaul** (2026-08-29). checkpoint-gate is green
  again (`src/abi/gen_header.zig` wired as `zig build gen-abi-header` and
  registered as a build-graph root; it had been an orphan since
  2026-08-26). The five slowest tests (~47s of a ~53s unified run) moved to
  a `test-stress` tier: checkpoint-gate and the per-change
  `zig build test` close-out run the unified suite alone, while the
  engine-production gate, primary-platform CI, and the per-merge-batch
  gate run the stress tier. Fixed-work PMU screening moved into
  `tools/perf/bench_v8/run_fixed_pmu.py` (`mise run perf-screen`) against
  the vendored suite; the external-checkout zoo runner (`tools/perf/zoo/`)
  is retired. `run_benchv8_compare.py` gained a `--suites` diagnostic
  subset (never headline-eligible) for single-benchmark high-sample
  iteration. `mise run watch -- <step>` keeps a resident incremental
  compiler on any focused target, and GUIDE B.6 no longer asks for
  quick-gate after every coherent edit. Follow-up (2026-08-30, after the
  F0 merge paid ~18 minutes of sequential gating): `mise run batch-gate`
  runs the whole per-merge-batch gate as one parallel build graph plus a
  parallelized gate_smoke (8min -> 3:13); the F0 ledger pins moved to
  comptime so `zig build check` catches drift; and the two reds the GC
  tranche left on checkpoint-gate are cleared (gc-slot tag on
  weakref_kept_alive, JSRuntime decl pin booked 174 -> 178), making
  checkpoint-gate 27/27 green on main again. Second follow-up
  (2026-08-30): the accumulated lane debris was reclaimed -- 49 finished
  worktrees removed (only clean trees; the `T test262` symlink typechange
  counted as clean), build caches deleted inside the kept dirty ones, and
  the repo's own `.zig-cache` trimmed of week-old entries, together about
  650 GB (disk 44% -> 27%); `mise run tidy` makes the cache trim and
  worktree-metadata prune repeatable. A backend experiment also
  re-verified the compile floor: the 0.16 self-hosted aarch64 backend
  still cannot produce a working Debug binary (minutes-long compile,
  corrupt ELF on a 12-line always_tail probe), so
  `forceLlvmBackendOnDebug` stays load-bearing and the ~95s unified
  compile remains the floor.

- **Docs: tree reorganized around a single work queue** (2026-08-25). The
  four queue documents (`impl-quality-backlog.md`,
  `maintainability-backlog.md`, `code-volume.md`,
  `perf/shared-vm-decomposition.md`) merged into `docs/backlog.md`;
  `security-boundary.md` merged into `LIMITATIONS.md`;
  `agents/issue-tracker.md` merged into `agents/project-experience.md`;
  `stack_bytecode_vm_design.md` merged into `docs/architecture.md` (Stack
  Bytecode VM Status chapter — the §8 PMU governance gate reference moved
  with it); the frozen 2026-07-27 qjs-align subsystem difference baseline
  removed. Git history retains all removed content.

- **Docs: superseded v7-suite historical records and the frozen zoo
  baseline (`docs/perf/zoo-status.md`) removed from the active tree**
  (2026-08-25 stale-doc cleanup; git history retains them).

- **Deprecated: the runtime plugin ABI** (2026-08-25, owner decision). The
  dynamic-plugin surface (`zjs.runtime.Plugin`, `PluginInstallOptions`, the
  `src/binding/ffi.zig` ABI) is frozen — correctness fixes only — and is
  superseded by the Fun Native Plugin design (FNABI v0.3,
  `docs/fun-native-plugin-design.md`); the loader moves to the `fun`
  repository at FNABI milestone M3. (The freeze terms lived in
  `docs/runtime-plugin-abi.md`, deleted with the surface on 2026-09-06; see
  the entry above.)

- **bench-v8 now vendors Octane 2.0 (V8 suite version 9)** instead of the
  8-benchmark version-7 suite (17 named results, 16 running, zlib
  skip-listed). The same commit adjudicated the apparent composite regression
  as reference-binary drift: the pinned QuickJS commit had been rebuilt with
  a newer compiler (GCC 13.3.0 → 16.0.1), which alone moves the composite by
  ~6.6%. Every published record must now carry the reference binary's
  fingerprint (hash + compiler); see `docs/perf/bench-v8-status.md`.

- **Adopted: the engine evolution plan (`docs/engine-evolution-plan.md`),
  the VM value-representation contract
  (`docs/vm-value-representation-contract.md`), and the QuickJS-alignment
  charter transition (`docs/qjs_alignment_charter_transition.md`)**
  (2026-08-24). The type-directed optimization plan
  (`docs/type-directed-optimization-plan.md`) was proposed alongside them.

- **Reduced interpreter and runtime code size** across
  `internal_builtins.zig`, `promise_ops.zig`, and `tailcall_dispatch.zig`
  under the refactor-policy identity gates.

- **`--gc-stats` reports GC pause percentiles again** (`p50`/`p95`/`p99`
  per collection ring). This supersedes the earlier entry below that removed
  the unimplemented "major GC" surface: the percentile *panel* returned with
  a real producer and consumer, while the removed phase/policy/page-geometry
  surface stays gone.

- **Each out-of-line payload now keeps its cycle-trace arm beside its
  destroy method.** `OrdinaryPayload`, `IteratorPayload`, `CollectionPayload`,
  `TypedArrayPayload`, `BoundFunctionPayload`, `ProxyPayload`,
  `ArgumentsPayload`, `ObjectDataPayload`, `VarRefPayload`,
  `FinalizationRegistryPayload`, `DisposableStackPayload`, `GlobalPayload`,
  `RealmRecordPayload`, `PromisePayload`, `FunctionRarePayload`,
  `GeneratorPayload`, and the native-function realm walk live next to
  teardown in `object_payloads.zig` / `generator_state.zig`.
  `Object.traceChildEdgesFallible` forwards to those methods. WeakRef /
  Buffer / RegExp / StdFile keep an explicit no-op trace documenting why
  they have no strong cycle edges. Object-level arms (shape, properties,
  iterator-next cache, dense elements, bytecode-function captures, mapped
  arguments, host class payloads) stay on `Object` because they share
  early-return / rewrite state. The G3 header-set guards and Q2 cycle-
  release tests stay green (docs/impl-quality-backlog.md, G4).

- **Fixed: replacing or deleting standard constructors still mutated result
  prototypes of several builtins.** After the Set combinators / `Map.groupBy`
  fix, remaining `constructorPrototypeFromGlobal` consumers were re-probed
  against ECMA-262 (pinned QuickJS as reference). Observable sites now take
  `%Intrinsic.prototype%` from the realm class table or `native_error_proto[]`:
  `RegExp()` without `new`, String `RegExpCreate` (`match`/`search`/`matchAll`),
  `Uint8Array.fromHex`/`fromBase64`, native-Error `Reflect.construct` fallback,
  `Error.prototype.stack` identity, `DisposableStack.move` /
  `AsyncDisposableStack.move`, and dispose `SuppressedError`. Cache-first JSON
  parse, TypedArray construct fallback, and embedder-only shape init already
  used or now prefer the class table; the global walk remains only as a last
  resort when no realm table is published. Differential probes match qjs on the
  constructors it implements; DisposableStack is spec-first (qjs lacks it).
  `regexp_fastpath` conversion is an O(1) class-table read, not a hot-path
  regression.

- **Breaking (0.2.0-dev): collection callback and native-record error ABIs are
  now explicit.** `CallbackCallFn` receives the authoritative `*JSContext`
  instead of a bare `*JSRuntime`; migrate callback implementations to read the
  runtime through `ctx.runtime` and set `CallbackHost.ctx` beside `.call`.
  `CallbackError` now contains only the seven hard/control outcomes
  (`JSException`, OOM, interrupt, process exit, stack overflow, timeout, and
  unhandled rejection); ordinary runtime failures are materialized as pending
  JavaScript exceptions in that context before crossing the seam. Internal
  native-record function pointers likewise declare `HostError` instead of
  `anyerror`, eliminating all fourteen dispatch-side `@errorCast` narrowings.
  This completes Q16's staged host-error boundary cleanup.

- **Breaking (0.2.0-dev): host and operation error types now describe their
  real transport boundaries.** `HostError` is now an alias of `RuntimeError`,
  removing all 48 raw std/backend members after Stage 1 converted module I/O
  and writer failures to JavaScript errors at their producer seams.
  `DynamicImportError` retains the runtime set plus only `AccessDenied`,
  `PermissionDenied`, and the host-hook fallback `Unexpected`; the settled-job
  and Atomics queue runners now use `RuntimeError`. Object property reads,
  `JSRuntime.installStandardGlobals`, `AppendStringError`, and the binding
  `GetPropertyError` inference no longer borrow the dynamic-import type.
  Embedders returning domain errors from ordinary external functions remain
  source-compatible: convert producer-specific failures to a JS exception at
  the boundary and return the runtime transport; dynamic-import callbacks must
  use the new three-member host extension. Fixed-capacity number/date/JSON and
  name formatters now discharge impossible capacity errors locally instead of
  polluting engine signatures. That Stage 2 commit deliberately left
  `CallbackError` and the native-record casts for the separately gated Stages
  3 and 4 recorded above.

- **Host I/O errors now become named JavaScript errors at their producer
  seams.** The exec-owned mapping is exhaustive over Zig's concrete module
  reader and output-writer error sets, so a stdlib change now fails to compile
  until its JS policy is reviewed. Both output implementations turn
  `WriteFailed` into a catchable `Error`; dynamic imports preserve the
  contextual not-found `ReferenceError`, missing-loader `TypeError`, and other
  I/O names; static module reads throw explicitly. A module host that cannot
  advance TLA work now reports `InternalError: module host made no progress`
  instead of leaking `OperationUnsupported` to the embedder. Native dispatch
  also fails closed: it never returns the exception sentinel without first
  installing a pending exception (docs/impl-quality-backlog.md, Q16 Stage 1).

- **`zjs --gc-stats` prints the collector's counters after a run**, and the
  public `GCStats` snapshot now carries the three honest counters that were
  previously visible only inside the engine: cycle-collection *entries*
  (distinct from completed rounds — the gap is aborted rounds), the last
  round's elapsed time, and zero-ref drains. Tuning a collector previously
  meant writing a Zig test; it can now be done against a real script.

- **The GC statistics struct no longer advertises numbers it does not keep.**
  `GCStats.cycles_collected` was assigned the *object* count on every
  successful collection — a different quantity from the name, with no reader;
  `rc_inc` / `rc_dec` and `CollectionResult.freed_bytecodes` had no references
  at all, and refcount traffic is deliberately left uninstrumented because a
  counter on that path is not cost-neutral. All four are removed (0.2.0-dev
  breaking window). The live counters — `collections`, `cycle_gc_count`,
  `cycle_gc_time_ns`, `last_collection_time_ns`, `freed_objects`,
  `failed_collections`, `last_failure`, `zero_ref_drains` — now document
  which write site maintains them. Groundwork for the GC refactor: tuning a
  collector against fields that read zero is worse than having no panel.

- **Fixed: a returning frame read its bytecode after releasing the object that
  owned it.** All three simple-teardown arms closed open var refs *after*
  freeing `current_function`, so a call whose function object held the last
  reference to its `FunctionBytecode` — reachable from JavaScript via a dynamic
  `Function(...)` call — read freed memory, and aborted outright under the
  allocation history of a shared-engine test run. The close now precedes the
  releases, matching the QuickJS ordering the adjacent comment cites. This
  closes the oldest entry in STATUS.md's known-defect list, whose original
  generator attribution is retracted there.

- **Parser diagnostics arc complete.** The last five user-reachable bare
  sites now explain themselves ("using declaration is not allowed at the
  top level of a script", "undefined label 'x'", "continue must target a
  loop label", "rest element may not have an initializer"); the only
  remaining bare `UnexpectedToken` returns are the three recorder
  helpers. Combined with the earlier batches, every syntax error now
  carries an exact position and a real message.

- **Q5d complete: every engine-internal parser invariant now reports as an
  internal compiler error** (132 sites total across both batches). A
  census-enforced safety boundary kept five genuinely user-reachable
  syntax-error sites out of the conversion; their messages get the final
  Q5c treatment instead.

- **Engine-internal parser invariant failures no longer masquerade as user
  syntax errors.** A dedicated `ParserInvariant` error routes them through
  the internal-compiler-error report instead of `SyntaxError:
  UnexpectedToken`; 59 sites converted in the first batch with per-family
  fault-injection proof of the routing, verdict- and emission-neutral for
  well-formed and malformed source alike.

- **The parser's remaining convertible error sites now report real
  found/expected diagnostics** — batch 3 converts the 25 deferred generic
  sites and 8 of 10 lookahead sites (the two holdouts are template-token
  internal invariants, reclassified into Q5d). Bare direct sites are down
  to 145, of which 137 are internal-invariant masks queued for Q5d
  conversion; a five-family pilot routes them through the existing
  internal-compiler-error arm.

- **The parser's binding, destructuring, class, and module-clause errors now
  name what they expected** ("expected binding name, got number", "expected
  export name, got ';'") — a second 101-site batch through the Q5 recorder,
  verdict-neutral (five-corpora emission byte-identical, test262 delta 0).
  Cumulative: 201 of 377 bare sites converted; the largest remaining class
  (140 sites) is internal invariants returning `UnexpectedToken`, now
  queued separately as Q5d.

- **A first 100 of the parser's 377 bare `UnexpectedToken` sites now report
  what they saw** ("unexpected '('", "expected X, got Y") through the Q5
  pending-diagnostic recorder, with rejection conditions untouched —
  verdict parity is emission-byte-identical on the five reference corpora
  and test262 is delta 0. 277 sites remain queued (Q5c).

- **IteratorClose now follows ECMA-262 for Set relation methods and Promise
  combinators.** An abrupt `next()` call or iterator-result validation no
  longer calls `return()`; Promise combinators preserve the original
  resolve/`then` exception when `return()` also throws; and
  `Set.prototype.isDisjointFrom` / `isSupersetOf` propagate early-exit close
  errors, including the TypeError for a non-object `return()` result. Under
  the 2026-08-22 spec-first ruling, the P1-P3 early-exit cases deliberately
  diverge from the pinned QuickJS, which still returns `false`.

- **The lexer moved out of `parser.zig`** (3,362 lines to its own file,
  lifted verbatim behind one alias — zero call sites changed; `parser.zig`
  falls from 20,769 to 17,408 lines). Emission is byte-identical
  (docs/impl-quality-backlog.md, Q13 precursor).

- **`parseStatementOrDeclSlow` is no longer a 936-line switch.** Each
  statement kind's case body is a named function; the dispatch prelude and
  order are unchanged and emission is byte-identical on the five reference
  corpora (docs/impl-quality-backlog.md, Q13 precursor).

- **Refactor gates are now tiered by measured risk.** The 2026-08-22 owner
  ruling separates identity-gated documentation/Debug work, cold changes
  covered by the cheap correctness gates, and hot changes that retain
  bench-v8 A/B with a calibrated `0.995` composite floor and per-suite
  dispersion envelopes. Test262 and small hot changes may share a merge
  window of at most three commits; ledgers now ride the work commit, and a
  post-window drift check backs Tier-1 merges that skipped A/B. Nightly and
  published-metric protocols are unchanged
  (docs/refactor-policy.md, 2026-08-22 amendment).

- **The cycle collector's three-phase driver moves to `object_gc.zig`**
  (H8 tranche 2, narrow seam). The first cut needed 23 private payload
  accessors made public and was rejected as encapsulation reversal; the
  ruling kept edge enumeration on `Object` — where the data lives — and
  moved only the 645-line trial-deletion driver, behind five
  purpose-named seams (`…ForCycleGc`). The four measured `align(16)`
  entry pins moved verbatim with their functions; zero call sites
  changed; all thirteen cycle-release guards pass. Gate under the
  2026-08-22 tiered rules: A/B 0.9988 with every suite in its dispersion
  envelope — pass, no lineage (docs/impl-quality-backlog.md, Q11 T2).

- **`object.zig` sheds 1,477 lines of content that was never the object
  model** (H8 tranche 1). The twenty out-of-line payload type definitions
  move to `object_payloads.zig`, the generator suspend machinery to
  `generator_state.zig`, `RealmValueSlot` to `context.zig` beside its
  consumers, and the libc file-close helpers to the runtime host seam.
  Forty-seven compatibility aliases keep every existing name resolving —
  zero call sites changed. `Object`/`ObjectStorage` field blocks are
  byte-identical and the layer gate stays at zero violations. Gate: A/B
  composite 1.0010 with every suite inside ±0.32%
  (docs/impl-quality-backlog.md, Q11 T1).

- **Fixed: a `'use strict'` directive no longer fails to reject
  `arguments`/`eval` as arrow parameter names.** Six arrow variants
  (parenthesized, bare, async × both names) accepted what the spec and
  the pinned QuickJS reject, because arrow parameter names were
  discarded before the directive prologue was parsed, while ordinary
  functions retained theirs for retroactive strict validation. Both
  shapes now share one retroactive check, and the error points at the
  offending parameter with an exact position. The other eighteen family
  shapes (plain functions, methods, accessors, class bodies, non-simple
  lists, sloppy controls) already matched and are pinned by the new
  matrix tests (docs/impl-quality-backlog.md, Q6d — found by Q6's own
  differential corpus).

- **`engine-production-gate` is green again (34/34).** The
  borrowed-atom checker flagged `parseFunctionDecl` storing a
  defer-freed name atom — a long-standing static false positive
  (red before this campaign's base), not a live ownership bug: the
  restore defer registered after the free defer runs FIRST under LIFO
  and clears the stored slot before the free executes. The store now
  carries the contract's borrowed-reason annotation, chosen over a
  refcount dup to avoid success-path churn. All six function-entry
  sites were audited for the same shape and are clean
  (docs/impl-quality-backlog.md, Q14).

- **Hygiene five-pack.** The dependency gate now forbids core→binding
  (closing the transitive core→exec hole; the one offending test moved to
  the binding tier). `--profile-opcodes` no longer prints
  structurally-zero counters as data: orphaned recorders and the dead
  activation path are deleted (release `.text` byte-identical) and
  unavailable fields say "not instrumented". 178 hand-rolled
  print-capture envelopes collapsed onto `helpers.expectPrints`
  (coverage-neutral; deinit-checked tests untouched). The last 10 C-ABI
  `export fn` shims in `libs/number_format.zig` were caller-less by
  whole-binary cross-reference and are gone (`.text` −4,052 bytes).
  `zjs.JSRuntime`'s public surface is recorded (167 decls) and pinned
  beside the JSValue pin, so it can no longer change silently
  (docs/impl-quality-backlog.md, Q10).

- **Removed the unimplemented "major GC" surface — which turned out to be
  live bookkeeping** (−333 net lines, `.text` −6,040 bytes). The
  incremental/concurrent collector's phases, policy switches, pause
  percentiles and page geometry had no consumer and no implementation,
  but the producer side RAN: every GC-control pass computed derived page
  state and costume statistics nobody read. Deleting it removes real work
  from `pollGC` and the cycle-removal entry; the GC-heavy benchmark
  suites both moved positive under the gate (Splay +0.8%, EarleyBoyer
  +0.8%, composite 1.0039). **Breaking (0.2.0-dev window):** removes 8
  `RuntimeOptions.gc_policy` fields, 33 `JSRuntime.gcStats` fields,
  `MajorPhase.mark_incremental`/`weak_fixpoint`/`finalize_mark`,
  diagnostic `Registry`/`SpaceAccount` members reachable via
  `JSRuntime.gc`, and `core.gc.logical_page_size` + two invariant tags.
  What remains measures real behavior: registry, thresholds,
  RSS/cgroup pressure, scheduler budgets, cycle counts/times/failures
  (docs/impl-quality-backlog.md, Q9).

- **The GC kind dispatch surface can no longer silently ignore a new
  kind.** `markChildrenCold`'s `else => {}` — which would have no-traced
  any future GC kind (the exact silent-gap shape behind the fast-array
  cache-edge leak) — is now an exhaustive switch with each no-op arm
  stating why it has no child edges; LLVM compiles it 312 bytes SMALLER.
  The four hand-copied kind sets in the zero-ref release path share one
  predicate. `ArgumentsPayload` gained its missing trace arm (destroy
  existed, trace did not — a leak lying in wait for the first embedder
  class that registers the kind), pinned by a cycle guard proven red
  before the arm landed. The unlink-without-destroy `releaseObject` is
  now test-only by name and compile guard. Gate: A/B composite 1.0000
  (docs/impl-quality-backlog.md, Q8).

- **Hardened `object.zig`'s unwritten conventions, at zero release-codegen
  cost.** The three meanings of `class_payload_kind == .none` (no payload /
  embedder-external / inline-payload class) are now a written contract on
  `ObjectStorage` with Debug-build proofs at the manual exclusion list;
  the cross-arm invariant that payload-pointer objects rely on zeroed
  trailing union bytes is documented at its read site; the `u` field's
  default no longer dangles a fake payload pointer for a literal that
  omits it; three out-of-file raw union reads carry the class/kind proofs
  their dispatch points discharge; and a stale `array_length` doc comment
  moved to the field that now owns the invariant. Gate: `.text`
  byte-identical (3,336,136 bytes both sides), so this is provably
  documentation-and-Debug-only (docs/impl-quality-backlog.md, Q7).

- **Defused the parser's state-restore hazard family** (the shape behind
  three historical real bugs). `parseFunctionExpr` no longer mutates
  parser state before its restore defer exists — the old window could
  leave a dangling atom on an error exit, unobservable today but armed
  against any future error-recovery path. The class static block's
  hand-written 14-field snapshot folded onto the collapsed mechanism as an
  explicit `StaticBlockContext` extension (the four extra displacements
  stay visibly distinct). Six function-entry sites that each saved a
  different hand-picked field subset now share one comptime
  `FunctionEntryContext` oracle. Bytecode emission is byte-identical on
  five corpora; a 20-case entry-state differential corpus agrees with the
  pinned QuickJS byte-for-byte before and after
  (docs/impl-quality-backlog.md, Q6).

- **Syntax errors now point at the error, not the end of the file.** Every
  parse diagnostic used to surface as `SyntaxError: UnexpectedToken` at an
  EOF position, because the position was recovered by re-lexing the whole
  source after the fact. The parser now records a pending diagnostic at
  the failure site (last writer wins), and 99.8% of error paths (467 of
  468) inherit the exact site — line AND column agree with the pinned
  QuickJS on every probe. `expectToken` failures additionally say
  "expected X, got Y". Internal compiler invariants (`InvalidBytecode`
  and siblings) no longer masquerade as user syntax errors: they report
  as internal compiler errors. Bytecode emission for valid sources is
  byte-identical (verified on five corpora incl. 100 KB); the gate read
  0.9983 and the pad lineage ruled it placement — RegExp flipped from
  0.977 to 1.028 across pads (docs/impl-quality-backlog.md, Q5).

- **The shared-engine test tier can now fail on a leak.** Two thirds of the
  suite ran on a shared engine whose teardown leak assert was structurally
  unreachable. `endSharedTest` now forces a cycle collection and enforces a
  module-accounted allocation high-water gate (tolerance 8 counts over a
  measured p95=0 / max=7 floor), with a self-diagnosing failure message;
  a deliberately leaky scratch test fired it on first contact. A new
  nightly step, `test-leak-census`, runs both shared tiers twice in one
  process and asserts second-pass growth is fully accounted — the durable
  form of the discovery machinery that found and fixed the two registry
  and compaction defects (docs/impl-quality-backlog.md, Q4 — item closed).

- **Ported property compaction: deleted slots are now reclaimed.**
  `Shape.deleted_prop_count` existed but nothing ever compacted, so every
  delete left a permanent tombstone — the shared realm's hidden globals
  object gained twelve per eval cycle, forever. The QuickJS mechanism now
  has a counterpart: on delete, once tombstones reach the reference
  predicate (≥ 8 and ≥ half the slots, deleted included), the unshared
  shape and its values are rebuilt stably in insertion order. Proven as a
  bounded sawtooth matching the reference's amplitude: the real
  hidden-globals object climbs to 150 slots / 72 tombstones and compacts
  back to 86 / 8 with all 78 live entries intact; churn probes are
  byte-equal to the pinned QuickJS; test262 unchanged. The gate read
  0.9973 and the pad lineage ruled it placement (sign flips across pads
  0/3/7). Root R3 of the shared-tier leak census
  (docs/impl-quality-backlog.md, Q4). Also hardened the shared-test
  baseline restore that the compaction exposed as order-sensitive.

- **Fixed: two runtime registries grew without bound on identical repeated
  work.** `internAutoInit` interned nothing — every registration allocated
  and appended, so a long-lived runtime re-installing the same builtin
  descriptors leaked list entries; it now returns the existing stable
  pointer on a full-field match. `registerExternalHostFunction` likewise
  appended forever; finalizer-free records — pure dispatch tuples whose id
  sharing is unobservable — now dedup, while finalized records keep
  distinct ids and their cleanup obligations. Root R2 of the shared-tier
  leak-census discovery (docs/impl-quality-backlog.md, Q4); regression
  guards pin both registries flat under repeated registration.

- **Fixed: `Array.of` and `Array.from` silently fabricated results where the
  spec throws.** Their four tail copies skipped `Set(A, "length")` for
  TypedArray results and used a strictness-gated write where the spec
  mandates `Set(..., true)` — so `Array.of.call(Uint8Array)` fabricated a
  Uint8Array (QuickJS: `TypeError: no setter for property`),
  `Array.from.call(Uint8Array, new Set([1,2]))` silently lost every element,
  and a non-writable `length` was ignored from sloppy callers. All four
  tails now share one typed-array-aware CreateDataPropertyOrThrow helper and
  an unconditional throwing length-Set, matching the pinned QuickJS
  byte-for-byte on the divergence probes; test262 is unchanged at
  49,778 prepared / 44,584 passed (docs/impl-quality-backlog.md, Q3c).

- **Fixed: `DOMException` was un-constructible through every path except
  plain `new`.** `Reflect.construct(DOMException, …)`,
  `Reflect.construct(Object, [], DOMException)` and
  `class X extends DOMException {}` all threw, because the shared
  builtin-constructor predicate did not list the name — an internal
  contradiction, since `new` (including through `.bind()`) worked. The
  predicate now recognizes it, and `DOMException.length` is 0 per WebIDL
  (was 2). The pinned QuickJS has no DOMException, so the oracle is
  internal consistency plus WebIDL (docs/impl-quality-backlog.md, Q3b).

- **Fixed: replacing or deleting `globalThis.Set`/`globalThis.Map` broke the
  Set combinators and `Map.groupBy`.** Result objects took their prototype
  from the writable global binding, so a polyfill assigning `globalThis.Set`
  — or `delete globalThis.Set` — made `union`/`intersection`/`difference`/
  `symmetricDifference` and `Map.groupBy` throw. They now resolve
  %Set.prototype% / %Map.prototype% through the realm's class-prototype
  table; the divergence probes match the pinned QuickJS byte-for-byte after
  the fix, untouched-global control included
  (docs/impl-quality-backlog.md, Q3a).

- **Added cycle-release regression guards for eleven GC payload families**
  (strong Map/Set entries, Promise result/reactions, ordinary
  error-stack/callsite slots, accessor pairs, FunctionRare fields, bound
  functions, DisposableStack resources, ObjectData, and ModuleRecord
  import.meta/eval-exception). Each test's cycle closes only through the
  family under test, so deleting that family's trace arm turns exactly that
  guard red — verified by deletion probes for every family, with the
  production tree restored byte-identically afterwards. Closes the
  test-coverage half of the GC blind spot (docs/impl-quality-backlog.md, Q2).

- **Fixed: a reference cycle through a fast array's cached iterator `next`
  edge was never collected.** The fast-array trial-deletion hot arm omitted
  the iterator-next cache edge that the authority trace and the
  ordinary-object hot arm both visit, while the destroy side owned it — so
  the miss was consistent across all three phases: not a use-after-free, a
  permanent leak. The arm now marks the same rare cache edge, and a
  bare-runtime regression test pins it. First defect confirmed out of the
  GC blind spot the 2026-08-20 audit declared
  (docs/impl-quality-backlog.md, Q1).

- **Fixed: `new Set`/`Map` bulk filled past a user-overridable adder.** The
  dense fast path calls the adder once per element but advances the iterator's
  cursor only once, at the end, and skips IteratorClose — invisible for the
  builtin `add`/`set`, plainly visible for a subclass's. A `Set` subclass whose
  `add` peeked at the source iterator read a cursor still at 0 (`peek 1` and
  every element, where QuickJS gives `peek 2` and every other one), and a
  subclass whose `add` threw let the error escape without running the
  iterator's `return`. The guard now also requires the adder to be the builtin;
  a subclass falls back to the ordinary IteratorStep/IteratorClose loop, and
  the fast path still triggers for plain `new Set([1,2,3])`.

- **Fixed: a skipped test that leaked was counted twice** in the timing test
  runner. The leak check turned the outcome into a failure but left the skip
  tally standing, so one test reported as `1 skipped; 1 failed`.

- **Collapsed the hand-written parser state snapshots** (−146 lines in
  `parser.zig`). The lexer cursor was saved and restored field by field at 11
  sites even though `takeLexerCursorSnapshot`/`restoreLexerCursorSnapshot`
  already existed and only three sites used them. Two of the 11 —
  the `export default function`/`class` lookaheads — restored six fields
  instead of seven, leaving `got_lf` (the flag automatic-semicolon insertion
  reads) describing the token the lookahead scanned rather than the current
  one; they now restore the full cursor. Separately, entering a class field
  initializer function saved, set and restored the same ten parser fields in
  three byte-identical copies, now `enterFieldInitFunction` /
  `leaveFieldInitFunction`. A class static block displaces four more fields on
  top of those ten and still open-codes them; that difference is documented at
  the type rather than silently unified.

- **One owner for the engine's error surface.** `RuntimeError` and `HostError`
  had three hand-written copies between them, and they had drifted:
  `context.DynamicImportError` was `HostError` spelled out member for member
  (123 = 123, both differences empty), and `host_function.CallbackError` — whose
  own doc comment called itself a mirror — was missing `StringTooLong`,
  `DerivedConstructorReturn` and `DerivedThisUninitialized`. The definitions now
  live in `core/errors.zig`, which core surfaces can name and which
  `exec.exceptions` re-exports.
  *Fixes an undefined-behaviour hazard:* `collection_adapter` bridged the gap
  with `@errorCast`, narrowing whatever `closure.callWithThis` returned down to
  `CallbackError`. That call actually returns `HostError`, so any I/O failure
  raised inside a `Map`/`Set` `forEach` or `groupBy` callback hit an error code
  outside the destination set — a safety panic in Debug, undefined behaviour in
  ReleaseFast. With the set defined correctly the cast is gone entirely.

- **Deleted 246 more unreferenced declarations, tree-wide** (−2,829 lines
  across 64 files). The previous sweep only looked at nine `exec/` files and
  only asked whether a name appears anywhere in the tree. Two corrections
  found the rest: deletion cascades, so the sweep runs to a fixed point
  (four rounds); and a **non-`pub` declaration is only visible in its own
  file**, so counting tree-wide hits lets a same-named declaration elsewhere
  keep a dead one alive. `call.zig`'s private `promiseCombinatorCall` — a
  143-line second implementation of the Promise combinators, with no
  callers — survived the first sweep exactly that way.
  `libs/unicode/data.zig` is excluded: its property tables are referenced by
  comptime name concatenation, which no text scan can see.

- **Deleted 118 unreferenced declarations across nine `exec/` files**
  (−2,087 lines, `.text` −1,596 bytes). Reachability was established by
  deletion rather than by inspection: the tree compiles, and Zig would have
  refused any name that still had a reference. Only top-level declarations
  were touched — struct fields are layout-bearing in this repository and stay.
  Names mentioned only in a doc comment count as referenced and were kept.

- **Fixed: `new Set`/`Map`/`WeakSet`/`WeakMap` indexed an Array argument
  instead of iterating it.** The dense read was selected on `isArray()`
  alone, so an array carrying its own `@@iterator` — or a patched
  `%ArrayIteratorPrototype%.next` — was silently indexed, while spread,
  for-of, `Array.from`, destructuring and `yield*` honoured it in the same
  process. The dense read now happens inside the iterator path, behind the
  same guard `appendSpreadValuesEnumerate` already applied, and reads from
  the iterator's target rather than the source.

- **Fixed: replacing `globalThis.Iterator` detached every builtin iterator
  prototype.** %IteratorPrototype% is a realm intrinsic, but it was resolved
  by walking the writable `Iterator` global and reading `.prototype` — so
  the first thing an Iterator-Helpers polyfill does broke Map, Set, Array and
  String iterators (`[...map.entries()]` threw `TypeError`) and made
  `Array.from(str.matchAll(re))` silently return `[]`. Deleting the binding
  was worse: two copies of the resolver invented two *different* synthetic
  bases, so Map and Array iterators stopped sharing one. It now reads the
  realm's class-prototype table, where the `Iterator` constructor already
  registered it, and the two copies became one.

- **Fixed: `Array.of`, `Array.from` and `Array.fromAsync` never ran a Proxy
  constructor's `construct` trap.** IsConstructor had two implementations;
  the one these entries used fell off its last branch with
  `class_id == c_closure`, so every Proxy answered false. The result was
  silent: a plain Array was fabricated and the trap counted zero calls, where
  the pinned QuickJS calls it once and returns the constructor's object. The
  two implementations are now one (−24 lines), and all 31 constructor shapes
  probed — plain/arrow/class/generator/async/method/getter, bound chains,
  builtins, and Proxies of each — agree with QuickJS.

- **Fixed: `Iterator.from` returned the source unwrapped when it should have
  wrapped it.** `Iterator.from` tests %Iterator%-instance-hood on the
  RESOLVED iterator, after `GetIteratorFlattenable`; this tested the SOURCE,
  before resolving, and only the branch where the source had no
  `@@iterator` could produce a wrapper at all. A class that is iterable,
  returns itself from `@@iterator`, and is not an %Iterator% therefore came
  back unwrapped with no iterator helpers on it —
  `Iterator.from(new T()).take(2)` threw `TypeError: not a function` where
  the pinned QuickJS returns the values. Three `sm/Iterator/from/*` test262
  cases left the exclusion list; the suite went 49,775 → 49,778 prepared,
  44,581 → 44,584 passed.

- **Fixed: `Number.prototype.toString(radix)` produced digits that name a
  different double.** For the 30 radices that are not a power of two, the
  digits did not identify the value they came from: 829 of 1,000 random
  doubles at radices 3/5/7/11/36 decoded back to a *neighbouring* double.
  Powers of two (2/4/8/16/32) were always exact, so hex and binary were never
  affected. The cause was a hand-rolled converter generating digits from an
  approximation; it is deleted (−96 lines) and the radix now goes through the
  same faithful `js_dtoa` port radix 10 already used — its wrappers had simply
  hard-coded 10. After: 0 of 2,100 round-trip failures, and byte-identical to
  the pinned QuickJS on all 2,100.

  Routing a non-decimal radix through that port also required fixing a stack
  buffer overflow on the way in: a `[9]u8` bounce buffer sized for the only
  radix that had ever reached it (10, whose `digits_per_limb` is exactly 9).
  Radix 3 writes 20 digits there. Upstream `dtoa.c` uses no temporary at all,
  and now neither does this.
- **`call_runtime.zig` sheds the Atomics, Reflect and iterator-protocol
  domains** (backlog H1, first three batches). Atomics: 1,000 lines and 44 top-level `pub fn`s moved to
  `atomics_ops.zig`, which until now held only an 88-line record table whose
  own doc comment pointed back at `call_runtime` for the method bodies.
  Reflect: eleven decls, interleaved with unrelated ones rather than
  contiguous, moved to `reflect_ops.zig`. Iterator protocol: fifteen decls to
  `iterator_ops.zig`, including `createIteratorResult`, whose four hand-written
  copies were merged earlier the same day. The call-chain file is down from
  7,510 lines / 208 pub fns to **5,811 / 144**. `Error.stack` and dynamic
  `Function` construction are still queued.
- **Merged the byte-identical cross-file duplicates** (−145 lines): 17 groups
  found by a same-name/same-body census, plus `monotonicNanos` (six copies,
  one of them an inlined body in a CLI root that could not reach
  `platform_clock.zig` — now exported through `internal_root`), and a
  `SourcePoint` struct declared identically in two resolver files.
- **One owner for the bare-runtime `ToString` fallback** (`core.value_string`,
  −363 lines). Seven copies of `appendValueString`, seven of its array leg,
  six BigInt cloners, five `appendUtf8CodePoint` wrappers and seven identical
  `AppendStringError` unions were spread across `exec/` and `core/`. Three of
  the four ways they had drifted were accidental and are now unified: float
  formatting (five copies used Zig's `{d}`, which renders `1e20` as `1e20`
  rather than the ECMAScript `100000000000000000000` — latent, since every
  reachable path coerces through a realm-aware `ToString` first), BigInt
  rendering, and string encoding. The fourth is real and survives as a
  comptime `Policy`: callers legitimately disagree about Symbols, primitive
  wrapper objects, and what a value with no `ToString` form becomes, so each
  site keeps exactly its previous behavior.
- **One owner for string-to-UTF-8 appending.** Eight hand-written copies of
  qjs `JS_ToCStringLen2` existed across `exec/` and `core/`, and their comments
  recorded the same defect being repaired independently six times: latin1
  0x80-0xFF must widen to UTF-8 instead of landing raw, and UTF-16 surrogate
  pairs must combine into one 4-byte sequence instead of encoding per unit. Two
  copies still carried an older form. Authority sank to
  `core.string.appendValueUtf8` — core, because two of the copies are core
  files, which cannot import exec. `value_ops.appendRawString` stays as the
  published embedding name and forwards. −99 lines.
- **Fixed: Map, Set and String iterator results had no prototype.** ES
  `CreateIterResultObject` (7.4.14) is `OrdinaryObjectCreate(%Object.prototype%)`,
  and the pinned QuickJS agrees, but `new Map().entries().next()` returned a
  null-prototype object — so `.hasOwnProperty` on an iterator result threw
  `TypeError: not a function` and `String(result)` threw. Array, generator,
  arguments, typed-array and RegExp iterators were already correct.

  The cause was duplication: four hand-written copies of
  `CreateIterResultObject` existed alongside the real owner, and two of them
  passed a null prototype. All four are now thin wrappers over
  `createIteratorResult`, each stating its ownership contract (three consume
  the value, the closure one borrows). The Map/Set dispatch arm was also
  discarding a realm it already held — it called the global-less `methodCall`
  where every neighbouring arm calls `methodCallObjectWithGlobal`. Regression
  test pins all eleven builtin iterator producers to the same answer.
- **Binary size: the release artifact went from 31.2 MB to 4.26 MB** (tarball
  7.5 MB → 1.9 MB), with the engine's own machine code down 8.2%
  (4,646,632 → 4,264,592 bytes stripped). Three independent items:
  - **Release tarballs now ship a stripped `zjs`.** 26 MB of the old artifact
    was DWARF that no user reads. `nightly.yml` strips post-link, before the
    configuration-signature check, so the check runs on the bytes that ship
    and `.text` plus the `.text.zjs.op_handlers` island stay byte-identical to
    the binary the gates measured — a `-fstrip` build does not (it moves
    `.text` by 40 bytes). arm64 macOS re-signs, because `strip` invalidates
    the ad-hoc signature. No build step strips by default: `nm`, `addr2line`
    and `perf` attribution all need the symbols.
  - **ReleaseFast CLIs panic with the message only** (−209 KB,
    `src/cli/panic_policy.zig`). The default handler drags in an ELF symbol
    reader, a DWARF line-table reader, a flate decompressor and two 30 KB-class
    sort instantiations to symbolize a trace that a stripped binary cannot
    resolve anyway. Debug and ReleaseSafe keep the full handler, so `zjs-dev`
    and every test artifact still print resolved traces.
  - **Sorting moved off `std.mem.sort` where stability is not observable**
    (−173 KB). `std.mem.sort` is `std.sort.block`, whose in-place merge costs
    ~22 KB of machine code *per element type*; eleven instantiations were
    258 KB. Sixteen call sites moved to `std.sort.heap` (~0.2 KB each); the
    two sites where equal elements are distinguishable and ordered —
    `Array.prototype.sort`'s default string order and the RegExp `v`-flag
    string set — keep the stable sort and now say why. Rule recorded in
    GUIDE A.7.

  Validation: `checkpoint-gate`, `test-exec`, test262 0/49775, and a
  refactor-policy rule-2 bench-v8 A/B against the merge base
  (`20ccc8c1`) — composite Score medians 2717 / 2716, ratio **1.0006**, with
  per-suite deltas mixed in sign (RegExp +3.4%, RayTrace −0.9%), the signature
  of layout noise rather than a semantic effect.
- **Fixed four independent memory leaks** that each tripped the
  `allocation_count == 1` teardown assert in `JSRuntime.deinit`, which had
  blocked running the Debug test262 suite as one process (it aborted after
  roughly 7,000 cases; `docs/borrowed_atom_audit.md` carried a standing
  "run by subtree" workaround). All four were pre-existing and independent:
  - `src/bytecode.zig`: `FunctionDef.deinitInitFailure` did not free
    `v2_builder`, which `initRootEmitter` attaches before the first token is
    lexed — so any lex error on a source's *first* token leaked the builder
    (`eval("@")`, every hashbang test, the Mongolian-vowel-separator test).
  - `src/core/runtime.zig`: teardown's cycle removal sweeps dead weak
    payloads, and a `FinalizationRegistry` whose target died enqueues its
    cleanup callback — re-growing the job queue's backing block *after*
    `job_queue.deinit()` had already run. `clearPendingFinalizationJobs`
    drained the entries but never released the storage.
  - `src/exec/string_builtin_ops.zig`: `stringCharCodeAtDirectHost` freed the
    receiver only when it was not already a string, but the coercion helpers
    dup a string receiver and always return an owned ref.
  - `src/libs/regexp.zig`: `reParseClassAtomOrRange` took ownership of a
    class-escape atom's `CharRange` from `getClassAtom` but dropped it on the
    rejection and rewind legs (`RegExp("[\d-a]","u")`, `RegExp("[a-\d]","")`).

  Verified by executing all 53,572 test262 files under the Debug runner with
  zero `allocation_count` hits. Four unrelated Debug asserts still block a
  whole-set single-process run; they are now enumerated in
  `docs/borrowed_atom_audit.md` §7.3 instead of being folded into one vague
  workaround.
- Fixed `zjs --leak-check` crashing on an otherwise clean run: the dynamic
  import loader scope's `defer` ran after `runtime.deinit()` and touched the
  destroyed runtime. The scope is now restored before teardown (`restore` is
  idempotent, so the defer becomes a no-op).
- **Gate and test audit (2026-08-19).** Reviewed every gate and test target
  for things that could be dropped or were over-built, then closed the two
  gaps the audit found.

  Removed:
  - The **NaN-boxed 8-byte JSValue representation** and everything that
    served it: `-Dzjs_nan_boxing`, the `NanBox` encoding namespace, the
    `test-altrepr` nested build, and the per-representation branches through
    `core/value.zig`, `exec/inline_calls.zig`, `exec/tailcall_dispatch.zig`
    and `core/jobs.zig`. No shipped platform used it (every release target is
    64-bit and ships `repr=tagged`), its A/B value was disproved in
    2026-08-07, and its guard had been a known-red gate since 2026-08-18 — a
    permanently-failing gate teaches nothing. `JSValue` is now unconditionally
    16 bytes. The `repr` component stays in the configuration signature, now
    derived from `@sizeOf(JSValue)`, so recorded signatures keep their meaning
    and the signature string is unchanged.
  - The **`perf-self-check` / `perf-self-update-baseline`** self-baseline gate,
    its checked-in baselines under `reports/perf/baseline/`, and
    `tools/perf/write_env.js`. Performance verdicts now come from bench-v8
    (published metric, and the rule-2 instrument) and the zoo (attribution).
  - The test262 runner's **`--regression-baseline`** flag and its per-directory
    comparison machinery: dead code with no caller anywhere, whose only tests
    tested itself, and which — when enabled — *suppressed* the zero-failure
    gate it was meant to strengthen.
  - The deprecated aliases `quick-check`, `checkpoint-check`, `test262-gate`,
    `test-compiler-v2`, and `-Dzjs_v2_layout`, as promised for this release.

  Added:
  - `test262-check` now runs **on every pull request** (linux-arm64). It is a
    zero-failure gate, so this is the sharpest semantic-regression signal
    available; previously a regression could live on `main` for up to a day
    until the nightly caught it.
  - `test -Dzjs_ownership_audit=true` now runs **nightly**, and a failing
    nightly opens or updates a tracking issue. That tier used to depend on a
    developer remembering to run it, which is exactly how the representation
    guard rotted unnoticed.
  - `test-oom` joins it too — but running it first revealed the target had
    been failing on `main` for a long time, unnoticed precisely because
    nothing ran it. Four independent pre-existing defects, all fixed:
    - **The native-call seam could claim an exception nobody installed.** It
      reports failure by returning the exception sentinel, and `nativeIsExc`
      asserts sentinel implies a pending exception — but when the heap was
      exhausted, building the Error object failed, `nativeFromHostError`
      swallowed that with `catch {}`, and the sentinel went out anyway,
      tripping the assert. `materializeRuntimeError` now falls back to the
      Realm's preallocated out-of-memory value, the same allocation-free path
      VM catch delivery and `throwInterrupted` already use.
    - **An uncaught out-of-memory reached the embedder as `error.JSException`.**
      Allocation failure is deliberately catchable (it becomes
      `InternalError: out of memory`), so the seam collapsed the original
      `error.OutOfMemory` into the generic JS-exception error and the other
      half of the contract — "paths without a JS catch handler still surface
      `error.OutOfMemory` to the embedder" — was not held. The runtime now
      carries `current_exception_out_of_memory` alongside the existing
      `current_exception_uncatchable` flag, and the embedder-facing
      `binding.JSContext` entry points restore `error.OutOfMemory` when the
      exception was never consumed by JavaScript.

      The restore happens **only** at that boundary. Widening the error inside
      the engine was tried and reverted: it changed control flow everywhere
      that treats `error.OutOfMemory` as a pre-user-code allocation failure —
      the pending exception stopped matching itself and was rebuilt (losing its
      stack), promise jobs re-queued on it, and module and async-generator
      paths turned it into a hard error instead of a rejection.
    - **`error.OutOfMemory` was missing from `errorNameForRuntimeError`**, even
      though `runtimeErrorInfo` maps it to `InternalError`. Because of the gap
      `pendingExceptionMatchesError` did not recognize an already-pending
      out-of-memory exception, so a second materialization cleared it and built
      a replacement — allocating on an exhausted heap and discarding the
      original error's stack.
    - **The for-of iterator-close path dropped exception flags.** It takes the
      pending exception, closes iterators (which can run user code), then
      re-throws the same value; `takeException`/`throwValue` reset the flags in
      between. Uncatchable interrupts already dodged this by returning early —
      out-of-memory cannot, so the flag is now carried across the round trip.

  Retained deliberately: `-Dzjs_force_gc` (demoted from an expected gate to a
  diagnostic instrument) and `JSValue.abi_encoding_revision` (fixed at 1;
  removing it would churn the plugin ABI fingerprint for no gain).

  The engine deletion was verified machine-code-identical under the
  identity gate. That verification also corrected the gate's own protocol:
  sampling three incremental rebuilds per source showed that *both* the
  changed and unchanged trees reach the same two images in arbitrary order,
  so a single build is not a verdict. `reports/identity/baseline.json` now
  records the admissible image **set** rather than one hash per build
  protocol, and `docs/refactor-policy.md` requires set membership.
- Reinstated **refactor-policy rule 2** (suspended 2026-08-19 for the
  maintainability campaign, which has closed) with bench-v8 as the measuring
  instrument in place of the 15-item zoo: it is the metric the project
  publishes, and its serial protocol costs about an hour per item against the
  zoo's half day — the cost that drove the gate into suspension. The
  comparison runner grew an explicit `--baseline` A/B mode that names the
  reference role in its output and JSON artifact, so a refactor A/B cannot
  later be misread as a QuickJS comparison.
- Switched the public performance metric to **bench-v8** (the V8 benchmark
  suite version 7 — the suite upstream QuickJS publishes its scores with)
  and vendored it unmodified under `tools/perf/bench_v8/suite/` (from the
  V8 repository at tag 7.9.317; BSD license headers retained). Added the
  pinned ABBA-interleaved comparison runner
  (`tools/perf/bench_v8/run_benchv8_compare.py`), a `perf-bench-v8`
  diagnostic build step, and `docs/perf/bench-v8-status.md` as the
  authoritative score page. The 15-benchmark zoo suite remains an internal
  diagnostic; its last baseline is preserved in `docs/perf/zoo-status.md`.

### 0.2.0 breaking public API

- Renamed the compiler directory `src/compiler_v2/` → `src/compiler/` (owner
  ruling 2026-08-19, reversing the earlier "ruled out" backlog entry). The
  build step `test-compiler-v2` → `test-compiler` and the option
  `-Dzjs_v2_layout` → `-Dzjs_compiler_layout`; both old names remain as
  deprecated aliases until the next release. The attested configuration
  signature string (`zjs-config-v2:compiler=v2,...`) is intentionally
  unchanged: "v2" is the compiler's published identity, not the directory
  name. Verified by the tightened identity-gate protocol: pre- and
  post-rename sources each produce the identical stripped-image set across
  both known build-bistability attractors (incremental-converged
  `e93b69e8`, cold-cache `5df9578f`), so the rename provably changes no
  machine code or data in either build mode.
- Removed the `zjs.host.NativeBinding` `Storage.inlineValue` constant alias.
  It was visually a sibling of the function `Storage.externalPtr(...)` while
  actually being a constant for the enum tag `.inline_value`. Migration: use
  the enum literal `.inline_value` directly.
- Named the parser's dual emission streams (backlog H13): the builder-stream
  State veneers dropped their `v2` prefix for `builder*` (`builderEmitOp`,
  `activeBuilder`, …), the parser-error facade free functions dropped the
  cryptic `v2F` prefix for `emitter*` (`emitterOp`, `emitterBindLabel`, … —
  the `F` meant "parser-error-typed Facade"), ~30 `v2_*` locals/fields
  dropped the prefix, and the dual-stream unions now tag their arms
  `temp`/`builder`. The compiler-contract F-5/F-6 dead code (never-assigned
  finally-label twin, four `*NoFinallyCapture` emitters,
  `emitForwardJump*`/`patchForwardJump`; −78 lines) is deleted. The
  identity gate first caught the deletion shifting `.text` by −432 bytes
  (a struct-field deletion is a layout payload — the QCP-1B class); it
  landed under the 2026-08-19 owner ruling that temporarily suspends the
  zoo A/B requirement, with the layout effect measured and recorded. The
  contract was also corrected where its description disagreed with the
  code (the fixup lists have live assertion guards and stay).
  `FunctionDef.v2_builder` keeps its name pending H10.
- Removed the historical `qjs*` function prefix entirely (527 unique names;
  owner ruling: mirroring quickjs.c is a transitional state, not the
  project's identity — names describe function, not provenance; alignment
  evidence stays in `// quickjs.c:N` comments and commit messages). 488
  names stripped mechanically after a collision pre-scan; the 39 collision
  cases were resolved individually: context-layer entry points gained a
  `Call` suffix (`arrayBufferResizeCall`, `dataViewGetCall`, …), five
  proved to be duplicates or dead forwards and were merged or deleted
  (including a byte-identical double `freeValueList` in one file), and two
  same-name/different-meaning pairs were disambiguated on both sides
  (`iteratorCloseValue` vs the opcode pair; `descriptorFromObject` /
  `descriptorFromObjectBare`).
- Deduplication pass (backlog H4/H5, landed under the zoo-gate suspension):
  every call site of the 17 `objectFromValue` copies that skipped the
  VarRef-cell `kind` re-check was classified — no live bug; the authority
  (checked, trusted-expression, and `expectObject` variants) sank to
  `core.value_semantics`, and the copies became forwards or explicit
  Trusted calls with the safety argument now named at each site. Deleted
  the 15 pure-forwarding `qjsIteratorZip*`/`qjsIteratorHelper*` shells in
  `call_runtime.zig` (zero external callers) and merged the
  `functionPrototypeFromGlobal` / `numberValue` duplicate implementations.
  GUIDE A.7 now requires a `mirror of <owner>, keep in sync` comment on any
  layering-forced helper copy.
- Disambiguated the remaining cross-file same-name traps:
  `tailcall_dispatch.run` → `runDispatchLoop` (vs the outer `zjs_vm.run`),
  `string_builtin_ops.iteratorNext` → `stringIteratorNext` (vs the
  iterator-protocol `iterator_ops.iteratorNext`), `vm_property`'s
  `fastInt32Add/Sub/Mul` → `checkedInt32Add/Sub/Mul` (overflow-intrinsic
  strategy, vs `vm_arith`'s deliberately widening `fastInt32*`), and the
  TDZ throw stragglers → `throwTdzReferenceError` /
  `throwGlobalTdzReferenceError`. Documented the throw-helper patterns,
  the `*ForFastPath` (ingredient) vs `*Fast` (fast variant) distinction,
  and the `X_ops` / `X_builtin_ops` split rule in `docs/architecture.md`.
- Renamed `src/exec/property_ic.zig` → `property_direct.zig`: the inline
  cache it was named after is long deleted; the file holds non-cached
  direct property fast paths. Deleted the always-false
  `cachedSetObjectDataPropertyForPutFastPath` zombie (zero callers; its
  "ABI stability" comment was stale). Disambiguated the H12 same-name
  traps: `call.zig`'s global-slot property walk is now
  `getValuePropertyViaGlobalSlots` (the full-semantics
  `object_ops.getValueProperty` is unchanged), and `object_ops`'s
  by-name define is now `defineDataPropertyByName` (the by-atom
  `property_ops.defineDataProperty` is unchanged). Documented the exec
  naming conventions (`vm_X` vs `X_ops` split, `Vm` suffix, `qjs*` prefix
  caveat, ownership-suffix policy) in `docs/architecture.md` and GUIDE A.7.
- Renamed `src/exec/vm_exception_ops.zig` → `exception_ops.zig` (all ~40
  importers already aliased it as `exception_ops`), unified the nine
  inverted `X_vm` import aliases onto their `vm_X` file names, renamed the
  cryptic `td` alias to `dispatch` in the cold-handler table, unified
  `module_exec` → `module_mod`, removed the duplicate `exec.eval` re-export
  (`exec.eval_entry` remains), and deleted the orphan 17-line
  `src/exec/iterator.zig` (no callers). Verified with the batch-tier
  identity gate.
- Refactor policy: added the identity-gate baseline registry
  (`reports/identity/baseline.json`) and the batch tier for mechanical
  rename campaigns (one identity closure per batch; per-change gating stays
  for hot-path structural changes).
- Naming-consistency pass (2026-08-19), verified change-free on both
  build-bistability attractors (stripped-image identity): unified the
  misleading `src/exec/` import aliases onto their file names (`class_vm` →
  `object_ops`, `collection_vm` → `array_ops`, `iter_vm` → `iterator_ops`,
  `date_vm` → `date_ops`, `weak_ref` → `builtin_glue`, `symbol_builtin` →
  `primitive_ops`, `buffer_builtin` → `buffer_ops`, `function_bytecode` →
  `bytecode`) and dropped the duplicate `object_ops` import in
  `tailcall_dispatch.zig` (backlog H3). Renamed `construct.zig`'s local
  `isErrorConstructorName` wrapper to `isConstructErrorObjectName` — it
  forwards a *different* predicate (no `SuppressedError`) than the
  identically named `vm_exception_ops` function (backlog H12 hazard).
  Fixed the remaining GUIDE A.7 style violations: `cur_func` → `curFunc`
  (parser), `h_*` comptime handler factories → `handler*` (dispatch colds),
  `unicode_script` → `unicodeScript` (regexp properties). GUIDE A.7 now
  documents the intentional mirror-name exemptions (`op_<opcode>` handlers,
  ported dtoa C ABI names, JavaScript-identifier constants, camelCase
  function-pointer vtable fields).
- Removed empty public shells with no in-tree users:
  `zjs.object.Builder`, `zjs.object.Template`, the `zjs.compile` namespace
  (`SourceKind` / `Options` / `Cache`), and the `zjs.error` namespace
  (`Info` / `Kind` / `Span`). Migration: delete those names; they had no
  producers.
- Removed dual handle aliases. `zjs.value.Ref` → `zjs.value.Persistent`;
  `zjs.value.WeakRef` → `zjs.value.Weak`; `zjs.host.NativeClass` →
  `zjs.host.NativeBinding.JSObject`.
- Ownership verbs: `JSValue.Persistent.release()` (transfer) is now
  `take()`. `HandleScope.exit()` is gone; use `deinit()` (idempotent, so
  an early close is another `deinit()`). `NativePin.release()` is gone;
  use `deinit()`. `Persistent.destroy(rt)` remains as a by-value
  compatibility wrapper. `Store` / `BorrowGuard` / `PropName.release`
  are unchanged.
- `dumpSmallInlineProbe` is no longer a public root export. The CLI probe
  is internal `printSmallInlineProbe`.
- `PropNameID.getProperty` now returns `GetPropertyError` instead of
  `DynamicImportError`. The error members are the same.
- Binding `string.zig` / `bytes.zig` forwarding shells are folded into
  `binding/root.zig`. Public `JSString` / `JSBytes` names are unchanged.
- `build.zig.zon` version is `0.2.0-dev`.
- Embedding tests now carry a same-file public-name list (not a freeze, not
  the removed `check_public_api.zig` tool). Adding or removing a public
  name must update that list in the same commit.

- Strict-mode functions now perform proper tail calls (ES2015 14.6): plain
  `return f(...)` tails — including conditional-expression arms and
  unconditional-jump joins — reuse the caller frame, so deep strict
  direct/mutual recursion (1e6) runs in constant stack and the reused
  caller drops off `Error.prototype.stack`. This is a deliberate,
  documented divergence from the pinned QuickJS. Sloppy code, method
  tails, `try`-protected calls, and eval-tails keep QuickJS-aligned
  frame growth and overflow behavior. See LIMITATIONS.md.
- Architecture `check_deps.js` now enforces compiler_v2 layering and scans
  `tools/` / `tests/` files that import the `zjs` module. The duplicate
  core-does-not-import-runtime Zig test is gone; the JS linter is the authority.
- Renamed `quick-check` → `quick-gate`, `checkpoint-check` → `checkpoint-gate`,
  and `test262-gate` → `test262-check`. Old names remain as deprecated aliases
  until the next release. See `docs/testing-graph.md`.
- Package `build.zig.zon` now ships COMPATIBILITY/LIMITATIONS/CONTRIBUTING/
  STATUS and `test262.conf`. mise pins node 24 and bun 1. Linux CI jobs
  install Node (checkpoint and production-gate invoke it via the build graph).
- Unified tests now compile through `internal_root` and assert they are a
  declared superset of it (Object is the only type fork). The previously
  dormant internal Object-identity test is collected (+2 unified tests).
- Scoped test targets now share one `src/<area>_tests.zig` shell ×
  `tests.<area>.` filter convention. Test names gained a `tests.` prefix
  (e.g. `core.test.foo` → `tests.core.test.foo`); counts are unchanged.
  New `test-embedding` target compiles the public `zjs` module.
- Extracted the shared exec/builtins test harness to `src/tests/helpers.zig`.
  `test-builtins` no longer compiles `src/tests/exec.zig`.
- Split `build.zig` into `build/{config,profiles,artifacts,tests,perf,gates}.zig`.
  Option order, step names, and the shipped `zjs` binary are unchanged.
- Refactor policy updated: maintainability work proceeds by risk zone;
  mechanical identity gates (binary-identical / .text-identical) may
  substitute for the zoo A/B where machine code provably does not change.
- Trimmed remaining local report write-outs: disconnected opcode-profile
  snapshots and `reports/test262-latest/` are gitignored. Dated `qjs-align`
  dumps stay in git history; new dated dirs keep markdown notes.
- Removed the public API symbol snapshot. The declaration surface is not
  frozen yet; `docs/public-api-contract.md` and the embedding tests remain
  the contract. `architecture-update-api-snapshot` and
  `tools/architecture/check_public_api.zig` are gone.
- Dropped the named `architecture-check` step. Checkpoint still runs the
  source lints (deps, OOM-panic, borrowed-atom, compiler-stage
  declarations) inline. The production gate adds the ReleaseFast `nm`
  check that those stage-boundary symbols remain independent.
- Dropped legacy-pipeline eradication (`check_legacy_pipelines_gone.js`).
  The remaining gate is `check_compiler_stage_boundaries.js`.
- Narrowed the OOM-panic lint to OutOfMemory-discard and
  catch-unreachable-on-alloc. The remaining allowlist entry is the
  rope-flatten last resort.
- Dropped redundant CLI `--seed 0` from live build commands and docs.
  `build.zig` already pins `graph.random_seed` to `0`.
- Removed `config-drift-gate`, `test262-smoke`, `final-switch-selftest`,
  and `tools/final-switch/`. Compile-time `attest()` and
  `config-signature-check` remain.
- Split validation docs so ReleaseSafe, `test-oom`, `test-altrepr`,
  force-GC, and ownership-audit are phase-close or change-triggered, not
  checkpoint or per-commit gates.
- Documentation terminal-state cleanup (2026-08-19): README/STATUS now carry
  the clean-field zoo headline (1.0304, `main@0c32a71c`) instead of the
  contaminated r3 numbers; stale claims fixed (per-opcode profiling works on
  `zjs-profile`; strict-mode PTC is landed); `qcp1_switch_decision.md`
  condensed to its close-out rulings (§0.1.6/§8/§8.5/§9 preserved);
  `borrowed_atom_audit.md` trimmed to the ownership contract and governance
  protocol; the 2026-07-27 subsystem baseline gained an errata header;
  `docs/README.md` reorganized by audience; `docs/agents/` merged 4 files
  into 2; the same-runtime verifier README moved to
  `tools/perf/same_runtime/VERIFIER.md`.

## 0.1.0 - 2026-08-17

First real release, replacing 0.1.0-alpha.1 and 0.1.0-alpha.2. The checked
test262 profile reports zero failures (44,581 pass). The 15-item javascript-zoo
geomean is 1.0141 vs QuickJS. Trusted-code embedding positioning is unchanged:
`zjs` is not an in-process sandbox for hostile JavaScript.

- Completed QCP-1B: removed the legacy Phase 1/2/3 compiler, dual comparator,
  and `-Dzjs_compiler` option. Deletion bisection traced the former crypto
  regression to shrinking `CompileContext` by one unused pointer, which
  perturbed Zig 0.16 whole-program native layout despite identical bytecode and
  allocation streams. The same-sized reserved word was used only as a control;
  the shipped fix restores explicit non-inlined boundaries around V2 lowering
  and the stack-size walk. The no-padding deletion candidate measures 1.0061x
  on the 15-item Zoo A/B. The diagnosis and amended verdict are in
  `docs/qcp1_switch_decision.md` §9.
- Fixed Array sort writeback when an indexed setter mutates a successor
  element, Error.prototype.stack setter edge cases, and TypedArray
  DefineOwnProperty detach-during-conversion semantics.
- Removed the historical C QuickJS performance comparison workflow and
  `perf-compare`; the checked performance gate is the ZJS self-baseline.
- Added a `run_runtime_profile.js` helper and `zig build perf-uri-profile`
  shortcut for checked single-script `--perf-json` artifacts that stay separate
  from multi-case microbench reports.
- Extended checked runtime-profile artifacts with opcode summary rows and added
  opcode-specific runtime diff metrics such as `opcode_count:get_var_ref0`.
- Added deterministic opcode-count ceilings to checked runtime-profile runs so
  focused hot-path fusions fail loudly when their opcode reductions disappear.
- Added `diff_runtime_profile.js` so single-script runtime profiles can be
  compared with explicit timing/allocation regression and improvement gates.
- Added an empty checked-local int32 for-loop range skip for loops whose body is
  only the induction update, reducing the `empty_loop` profile from 60007
  opcodes to 7 while preserving interrupt fallback.
- Added a dense array indexed append fast path for simple int32 multiply/mask
  element expressions while preserving inherited indexed setter fallback.
- Added a var-local int32 arithmetic-store fast path for microbench-style loop
  bodies without changing loop condition or post-update semantics.
- Added narrow `String.fromCharCode` and `Math.min`/`Math.max` method-call fast
  paths that keep object coercion and monkey-patched methods on the generic
  call path.
- Added local, closure, and global simple-numeric bytecode call add-store fast
  paths for tight `acc += fn(i, c)` loops while preserving non-simple function
  side effects.
- Tightened the URI 4-byte decode comparison fast path to use a borrowed
  native-method guard instead of transient method value dup/free churn.
- Shortened the percent-hex simple string add-store path used by URI decode
  fixtures by avoiding the transient helper result value before global writeback.
- Added a guarded `make_var_ref` assignment fusion for `global = string +
  percentHex(int)` loops so reference setup and `put_ref_value` are skipped when
  all participating bindings are ordinary global data properties.
- Added matching global-string and literal-prefix declaration initializer
  fusions for `var next = prefix + percentHex(int)` and `var next = "%F0%A0" +
  percentHex(int)`, eliminating the URI 4-byte profile's remaining
  `get_var_ref0` executions.
- Added a backward-goto global int32 condition fusion that replays the target
  loop condition directly at the backedge when it is an ordinary global data
  comparison, reducing the URI 4-byte profile's `get_var` executions by 66576.
- Extended the URI strict-equality branch-count fusion to ordinary global data
  `count++`, reducing the URI 4-byte profile's `if_false8` executions from
  65536 to 1 and its `get_var` executions by another 65535.
- Refreshed active documentation to match the current build steps, test262
  boundary, ZJS self-baseline performance gate, and tracked active reports.
- Removed the completed Production v1 roadmap from the active docs; public API,
  compatibility, and release-checklist docs are the current authorities.
- Merged the small Compatibility v1 summary into `COMPATIBILITY.md` so the
  compatibility boundary has one active source of truth.
- Removed old one-off test262 slice and QuickJS comparison report directories
  from `reports/`; the active gate report remains `reports/test262-latest/`.
- Removed the future-oriented Bun/uWS GC design note from the active docs; the
  current GC boundary remains documented in `README.md` and `LIMITATIONS.md`.
- Removed the unused opcode-alignment report snapshot from `reports/`.
- Removed historical phase/ledger documents from the active tree:
  `docs/gc-memory-lifecycle-candidates.md`, `docs/perf/roadmap.md`, and
  `reports/perf/baseline/phase-a-baseline.md`.

## 0.1.0-alpha.2 - 2026-05-22

- Added an explicit `--leak-check` CLI strategy to cleanly execute engine deinitialization (`runtime.deinit()`) and perform GPA memory validation on demand.
- Created `LIMITATIONS.md` providing architectural transparency regarding garbage collection circular references, FFI, CommonJS vs ESM, and standard library support.
- Created `COMPATIBILITY.md` detailing the active test262 test suite configuration, skipped features/categories, and recently added progressive ES2024+ features.
- Refactored `README.md` first-screen positioning text and added references to compatibility and limitation docs.

## 0.1.0-alpha.1 - 2026-05-20

- Reached a clean active local test262 gate: 0 errors and an empty
  `test262_errors.txt`.
- Improved WeakMap, WeakSet, WeakRef, and FinalizationRegistry handling for
  non-registered Symbol weak keys and targets.
- Fixed strict script top-level `this`, bound function `toString`, TypedArray
  descriptor behavior, BigInt typed array 64-bit wrapping, Array species
  creation, Annex B direct eval function behavior, and multiple RegExp
  Unicode/property escape paths.
- Added focused Zig regression coverage for the compatibility fixes above.
- Added public release metadata and package manifest paths.
