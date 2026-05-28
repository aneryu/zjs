# fun Runtime MVP Design

## Summary

`fun` should first become a minimal usable JavaScript runtime, not an
all-in-one toolkit. The MVP supports direct file execution and a REPL with a
small Node-shaped host API surface. It does not support `fun eval`, `fun run`,
CommonJS, package resolution, Bun APIs, TypeScript execution, a test runner, a
bundler, or package management.

The implementation is JS-first, but all loader, source, diagnostic, and runtime
interfaces must remain TypeScript-ready. `.ts`, `.tsx`, `.mts`, and `.cts`
inputs are recognized and rejected with explicit diagnostics until `zjs`
supports the required TypeScript frontend path.

## Goals

- `fun` with no arguments enters a REPL.
- `fun <file> [...args]` executes a JavaScript ESM entry file.
- Local relative and absolute ESM imports work.
- `node:` builtin imports work for the MVP host API subset.
- The host API subset includes `console`, basic `process`, global timers,
  `node:fs`, and `node:fs/promises`.
- Diagnostics are structured and shared by file execution and REPL behavior.
- Runtime execution reaches `zjs` only through the `src/js` facade + `src/runtime/vm`
  (the sole deep-coupling layer per `fun_zjs_subtree_architecture.md`).

## Non-Goals

- No `fun eval` command.
- No `fun run <file>` command.
- No explicit `fun repl` command. `fun repl` is treated as an attempt to execute
  a file named `repl`.
- No CommonJS or `require`.
- No bare package resolution, npm package loading, or package `exports`.
- No Bun API surface.
- No test runner, bundler, package manager, or watch mode.
- No TypeScript execution in this MVP.
- No Node or Bun compatibility claim beyond the documented small API subset.

## CLI Contract

The CLI has only two execution modes:

- `fun`: enter REPL.
- `fun <file> [...args]`: execute `<file>` and pass remaining arguments through
  to the script.

`--help`, `-h`, `--version`, and `-v` remain special flags. All other non-flag
arguments are treated as file paths or script arguments. `run`, `eval`, and
`repl` are not subcommands.

For file execution, `process.argv` should be:

```text
[fun_executable_path, entry_path, ...script_args]
```

For REPL, `process.argv` should be:

```text
[fun_executable_path]
```

The CLI must not interpret script arguments in the MVP. A future design can add
`--` or runtime flags if needed.

## Architecture

> The module structure and data flows below describe the **target shape** for the
> MVP. As of the current scaffold, only CLI parsing, core classification, and
> placeholder boundaries exist. Real execution, loader I/O, diagnostics, and the
> `zjs` adapter are still ahead (primarily M3–M4).

```text
fun CLI
  -> no-arg REPL or file execution
  -> diagnostics
  -> loader / resolver
  -> runtime source input
  -> zjs adapter
  -> host APIs
  -> jobs / timers
  -> exit code
```

### `src/cli`

`src/cli` parses only the small CLI contract above and maps diagnostics to
process-level behavior. It should not contain runtime execution logic.

### `src/repl`

`src/repl` becomes part of the MVP. It owns the interactive loop and delegates
input evaluation to `src/runtime`. A REPL session must reuse one runtime context
so variables and global state survive across inputs. History, completion, and
advanced multiline editing are deferred.

### `src/diagnostics`

`src/diagnostics` should provide the shared diagnostic model for usage, loading,
resolution, unsupported source kind, runtime, host, and REPL input errors.
Diagnostics should support path, line, column, source kind, message, and exit
code fields where available.

### `src/core`

`src/core` owns shared source metadata such as source kind, parse goal, and
package type. The MVP executes JavaScript first, but these types must represent
JavaScript, TypeScript, JSX, TSX, JSON, and unknown inputs.

### `src/resolver`

`src/resolver` supports only:

- relative local ESM specifiers;
- absolute local ESM specifiers;
- `node:` builtin specifiers for the MVP host API subset.

Bare package specifiers are rejected with an unsupported-package diagnostic.

### `src/loader`

`src/loader` reads the entry file and local ESM dependencies. A module record
should preserve source bytes, path, source kind, parse goal, and ownership. TS
source kinds are recognized but rejected before execution.

### `src/runtime`

`src/runtime` is the only package layer allowed to import `zjs` or
`quickjs_zig_engine`. File execution and REPL evaluation both go through this
module. Suggested internal files are:

- `zjs_adapter.zig`: creates, owns, and destroys the `zjs` engine/context.
- `source.zig`: converts loader records into `zjs` compile inputs.
- `host.zig`: registers host APIs and builtin modules.
- `diagnostic.zig`: converts `zjs` errors into `fun` diagnostics.

### `src/runtime/host`

The MVP host API is Node-shaped but intentionally small:

- `console.log` and `console.error`;
- `process.argv`, `process.cwd()`, and `process.env`;
- global `setTimeout`, `clearTimeout`, and the minimum timer machinery needed
  by them;
- `node:fs`;
- `node:fs/promises`.

This is not a Node compatibility claim. Each supported function must be covered
by local tests before it is documented as available.

## File Execution Data Flow

```text
argv
  -> cli.parse
  -> Command.file(path, script_args)
  -> loader.loadEntry(path)
  -> core.detectSourceKind(path)
  -> reject unsupported TS kinds for now
  -> runtime.createContext(options, host)
  -> runtime.runModule(entry_source)
  -> resolver handles local ESM imports / node: builtins
  -> loader loads dependent local modules
  -> runtime.runJobsAndTimers()
  -> diagnostics / exit code
```

`.js` and `.mjs` are executable JavaScript inputs. `.ts`, `.tsx`, `.mts`, and
`.cts` are recognized and rejected with `unsupported_source_kind`.

## REPL Data Flow

```text
argv empty
  -> cli.parse
  -> Command.repl
  -> runtime.createContext(options, host)
  -> repl.loop
      -> read input
      -> runtime.evalReplInput(input)
      -> runtime.runJobsAndTimers()
      -> print result or diagnostic
      -> keep context alive
```

The REPL prints diagnostics but keeps the session alive after recoverable
errors. EOF exits normally with status 0. A fatal engine state such as OOM or an
internal runtime failure can terminate the REPL with a non-zero status.

Top-level await, rich formatting, history, completion, and multiline editing are
not MVP requirements. They should remain undocumented unless implemented and
covered by focused tests.

## Diagnostics and Exit Codes

The shared diagnostic shape should include:

```text
kind
message
path?
line?
column?
source_kind?
exit_code
```

Required diagnostic kinds:

- `usage_error`;
- `file_not_found`;
- `unsupported_source_kind`;
- `resolve_error`;
- `load_error`;
- `runtime_error`;
- `host_error`;
- `repl_input_error`.

Suggested initial exit codes:

- `0`: success;
- `1`: runtime, host, or general error;
- `2`: usage error;
- `3`: load, resolve, or source-kind error.

File execution exits on errors. REPL prints recoverable errors and continues.
Program output goes to stdout. Diagnostics go to stderr.

`fun` should prefer structured errors from `zjs`. If `zjs` temporarily exposes
only formatted strings for some error classes, `fun` may display those strings
as a fallback, but must not parse them as stable data.

## Testing and Validation

### Unit Tests

- `fun` with no arguments parses to REPL.
- `fun app.js a b` parses to file execution with script args.
- `--help`, `-h`, `--version`, and `-v` remain special.
- `run`, `eval`, and `repl` parse as ordinary file paths.
- Source kind detection covers JS, MJS, TS, TSX, JSON, and unknown files.
- Resolver classification covers relative paths, absolute paths, `node:`
  builtins, and unsupported bare package specifiers.
- Diagnostics map to stable exit codes.

### CLI Fixtures

- `fun` enters REPL; tests can feed stdin and EOF.
- `fun hello.js` executes and prints output.
- `fun hello.js a b` exposes script args through `process.argv`.
- Local ESM imports work.
- `node:fs/promises.readFile` can read a fixture file.
- TS entry files produce `unsupported_source_kind`.
- `fun repl` reports file not found when no file named `repl` exists.

### zjs Integration Smoke Tests

- Runtime context creation and teardown works.
- File execution runs through the adapter rather than the `zjs` CLI.
- Runtime errors convert to `fun` diagnostics.
- REPL inputs reuse the same context.
- Host APIs are visible to JavaScript.
- Jobs and timers can be pumped after evaluation.

## Acceptance Criteria

- `fun` enters a REPL.
- `fun <file> [...args]` executes a JavaScript ESM entry.
- Relative and absolute local ESM imports work.
- `console`, basic `process`, global timers, `node:fs`, and
  `node:fs/promises` are available as documented subset APIs.
- TypeScript-like source kinds are recognized and rejected with structured
  diagnostics.
- `fun eval`, `fun run`, and explicit `fun repl` are not commands.
- CLI and REPL share the same diagnostic model with different control flow.
- `zjs` is accessed only through `src/runtime`.
- No Node, Bun, or TypeScript compatibility claims are made beyond tested MVP
  behavior.
