#!/bin/sh
set -eu

repo_root=$(git rev-parse --show-toplevel)
git_dir=$(git rev-parse --path-format=absolute --git-dir)
common_dir=$(git rev-parse --path-format=absolute --git-common-dir)

if [ "$git_dir" = "$common_dir" ]; then
    printf '%s\n' 'worktree-init: skipped (main worktree)'
    exit 0
fi

case "$common_dir" in
    */.git) main_root=${common_dir%/.git} ;;
    *)
        printf '%s\n' "worktree-init: cannot derive main worktree from $common_dir" >&2
        exit 1
        ;;
esac

main_test262=$main_root/test262
if [ ! -d "$main_test262/test" ]; then
    printf '%s\n' "worktree-init: main worktree test262 corpus is unavailable at $main_test262" >&2
    exit 1
fi

cd "$repo_root"
if [ -d test262/test ]; then
    if [ -L test262 ]; then
        git update-index --skip-worktree -- test262
    fi
    printf '%s\n' 'worktree-init: skipped (linked worktree test262 is already initialized)'
    exit 0
fi

if [ -L test262 ]; then
    rm -- test262
elif [ -d test262 ]; then
    if ! rmdir test262; then
        printf '%s\n' 'worktree-init: refusing to replace non-empty test262 without a test/ corpus' >&2
        exit 1
    fi
elif [ -e test262 ]; then
    printf '%s\n' 'worktree-init: refusing to replace non-directory test262' >&2
    exit 1
fi

ln -s "$main_test262" test262
git update-index --skip-worktree -- test262

if [ -n "$(git status --porcelain=v1 -- test262)" ]; then
    printf '%s\n' 'worktree-init: test262 remains dirty after initialization' >&2
    exit 1
fi

printf '%s\n' "worktree-init: linked test262 -> $main_test262 (reused main worktree corpus)"
