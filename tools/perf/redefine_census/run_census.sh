#!/bin/bash
# P7-51A census runner. Counting only -- no timing, so no exclusive host lock.
# Each corpus entry runs once in its own process; the temporary counter in
# src/core/redefine_census.zig prints one line to stderr at exit.
B=${1:?binary}
ROOT=$(cd "$(dirname "$0")/corpus" && pwd)
emit() {  # group, name, file
  local out
  out=$("$B" "$3" 2>&1 >/dev/null | grep '^ZJS_REDEFINE_CENSUS ' | tail -1)
  [ -z "$out" ] && out='{}'
  echo "$1|$2|${out#ZJS_REDEFINE_CENSUS }"
}
for f in "$ROOT"/named_eval/*.js; do emit named_eval "$(basename "$f" .js)" "$f"; done
for f in "$ROOT"/microbench/*.js;  do emit microbench "$(basename "$f" .js)" "$f"; done
for f in "$ROOT"/wrapped/*.js;     do emit wrapped   "$(basename "$f" .js)" "$f"; done
