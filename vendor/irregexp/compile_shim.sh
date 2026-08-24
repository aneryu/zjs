#!/bin/sh
set -eu
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${1:-/tmp/irregexp-smoke}"
CXX="${CXX:-g++}"
FLAGS="-std=c++20 -fno-exceptions -fno-rtti -O1 -g
  -DCOMPILING_IRREGEXP_FOR_EXTERNAL_EMBEDDER
  -I${ROOT}/vendor
  -Wno-unused-parameter -Wno-unused-variable -Wno-sign-compare
  -Wno-missing-field-initializers"

SRCS="
  ${ROOT}/vendor/irregexp/RegExpShim.cpp
  ${ROOT}/vendor/irregexp/zjs_irregexp.cpp
  ${ROOT}/vendor/irregexp/imported/regexp-ast.cc
  ${ROOT}/vendor/irregexp/imported/regexp-bytecodes.cc
  ${ROOT}/vendor/irregexp/imported/regexp-bytecode-generator.cc
  ${ROOT}/vendor/irregexp/imported/regexp-bytecode-iterator.cc
  ${ROOT}/vendor/irregexp/imported/regexp-bytecode-peephole.cc
  ${ROOT}/vendor/irregexp/imported/regexp-compiler.cc
  ${ROOT}/vendor/irregexp/imported/regexp-compiler-tonode.cc
  ${ROOT}/vendor/irregexp/imported/regexp-error.cc
  ${ROOT}/vendor/irregexp/imported/regexp-interpreter.cc
  ${ROOT}/vendor/irregexp/imported/regexp-macro-assembler.cc
  ${ROOT}/vendor/irregexp/imported/regexp-parser.cc
  ${ROOT}/vendor/irregexp/imported/regexp-stack.cc
  ${ROOT}/vendor/irregexp/shim_smoke_test.cpp
"

# shellcheck disable=SC2086
${CXX} ${FLAGS} ${SRCS} -o "${OUT}"
echo "built ${OUT}"
