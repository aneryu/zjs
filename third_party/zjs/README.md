# third_party/zjs — Git Subtree of the zjs Engine

This directory **must** contain a full checkout of
https://github.com/aneryu/zjs (the Zig port of the QuickJS-derived engine used
by `fun`).

## Initialization (one-time)

From the `fun` repository root:

```sh
# Recommended: full history (best for blame on GC, parser, bytecode, module bugs)
git remote add zjs git@github.com:aneryu/zjs.git || true
git fetch zjs

git subtree add \
  --prefix=third_party/zjs \
  zjs main \
  -m "Import zjs as subtree (full history)"
```

**Do not add `--squash` on the first import** unless you explicitly decide that
zjs history is no longer useful for `git blame` inside `fun`. The project
preference (see `docs/fun_zjs_subtree_architecture.md` §5.1) is to keep history.

### Local development (no network, sibling checkout)

If you have `/Users/aneryu/zjs` (or any local clone) already:

```sh
git subtree add \
  --prefix=third_party/zjs \
  /Users/aneryu/zjs main \
  -m "Import zjs as subtree (local)"
```

## After population you can:

- `zig build zjs` — build the zjs CLI from the vendored tree
- `zig build fun` — build fun (which links the engine module)
- Run zjs's own tests via its build steps (once wired)

## Size note

The tree includes `test262/`, reports, and full history. Expect >100 MiB after
import. CI or constrained environments may later use a sparse checkout or
post-import exclusion of `test262/` for the `fun` build (the engine + cli paths
are the only ones required for `zig build fun` / `zig build zjs`).

## Updating later

```sh
git fetch zjs
git subtree pull --prefix=third_party/zjs zjs main -m "Update zjs subtree"
```

## Pushing fun changes back to zjs

See the exact `git subtree push` / `split` workflow and the critical commit
splitting rule in `docs/fun_zjs_subtree_architecture.md` §5.3–5.4.

Never mix zjs engine changes and fun runtime changes in the same commit when you
intend to split/push.

## References

- Full rationale and commands: `docs/fun_zjs_subtree_architecture.md` §2, §5, §17 (Phase 1), §22 (risks)
- Architecture layering: same document §3–4
