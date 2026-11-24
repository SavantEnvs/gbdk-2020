#!/usr/bin/env bash
#
# mayhem/build.sh — build gbdk-2020's host support tools (gbdk-support/*) twice:
#
#   1. FUZZ build  -> mayhem/out/fuzz/<tool>   afl-clang-fast + $SANITIZER_FLAGS + $DEBUG_FLAGS.
#      Every tool is a main() that reads files named on argv and exit()s on bad input, so each
#      target is the real CLI run as an AFL (`afl: true`) file-input target.
#   2. ORACLE build -> mayhem/out/plain/<tool>  the project's normal flags (no sanitizers, no
#      instrumentation) for mayhem/test.sh.
#
# The upstream Makefiles hardcode gcc / strip (-s, strip), so the sources are compiled directly with
# the same source lists. The top-level Makefile needs an SDCC toolchain (gbdk-lib) and is not used.
set -euo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
: "${SRC:=/mayhem}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"
S="$SRC/gbdk-support"
OUT="$SRC/mayhem/out"
rm -rf "$OUT/fuzz" "$OUT/plain" "$OUT/obj"
mkdir -p "$OUT/fuzz" "$OUT/plain" "$OUT/obj"

COMMON_DEFS='-Wno-incompatible-pointer-types -DGBDKLIBDIR="/opt/gbdk"'

# AFL compilers wrap clang (reached by name); the oracle uses $CC/$CXX.
AFL_CC=afl-clang-fast
AFL_CXX=afl-clang-fast++
export AFL_QUIET=1

FUZZ_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -O1"
PLAIN_FLAGS="-O1 $COVERAGE_FLAGS"

# LeakSanitizer off at build time (leaks are not the bug class fuzzed here).
$AFL_CC $FUZZ_FLAGS -c "$SRC/mayhem/lsan_off.c" -o "$OUT/obj/lsan_off.o"

# build_c <tool> <extra cflags> <sources...>
build_c() {
  local tool="$1" extra="$2"; shift 2
  # shellcheck disable=SC2086
  $AFL_CC $FUZZ_FLAGS $COMMON_DEFS $extra "$@" "$OUT/obj/lsan_off.o" -lm -o "$OUT/fuzz/$tool"
  # shellcheck disable=SC2086
  $CC $PLAIN_FLAGS $COMMON_DEFS $extra "$@" -lm -o "$OUT/plain/$tool"
}

build_c bankpack   "" "$S"/bankpack/*.c
build_c gbcompress "" "$S"/gbcompress/*.c "$S"/gbcompress/zx0/*.c "$S"/gbcompress/zx0/libdivsufsort/*.c
build_c ihxcheck   "" "$S"/ihxcheck/*.c
build_c makebin    "" "$S"/makebin/makebin.c
build_c makecom    "" "$S"/makecom/*.c
# romusage: area_item.exclusive is left uninitialized for ROM-file areas (banks.c:226 reads it), so
# UBSan's `bool` check fires on every multi-area ROM input; relax only that check for this tool.
build_c romusage   "-fno-sanitize=bool -I$S/romusage/src" "$S"/romusage/src/*.c
# png2hicolorgb: its vendored C lodepng (lodepng.c:326, `b[0] << 24`) shifts into the sign bit on
# every PNG; relax only UBSan's shift-base check for this tool (ASan and the rest of UBSan stay on).
build_c png2hicolorgb "-fno-sanitize=shift-base -I$S/png2hicolorgb/src -I$S/png2hicolorgb/src/lodepng -I$S/png2hicolorgb/src/hicolor" \
  "$S"/png2hicolorgb/src/*.c "$S"/png2hicolorgb/src/lodepng/*.c "$S"/png2hicolorgb/src/hicolor/*.c

# <tool>-staged: the same tool sources (unmodified, main renamed by -Dmain=staged_tool_main) behind
# mayhem/harnesses/stage_input_main.c, which copies the fuzz input to <scratch>/input<ext> and runs the
# tool there. These tools pick their parser by, or derive sibling file names from, the input's
# extension, and Mayhem's AFL runs did not honour `filepath:` (see the harness header).
$AFL_CC $FUZZ_FLAGS -c "$SRC/mayhem/harnesses/stage_input_main.c" -o "$OUT/obj/stage_input_main.o"
build_staged() {
  local tool="$1" extra="$2"; shift 2
  # shellcheck disable=SC2086
  $AFL_CC $FUZZ_FLAGS $COMMON_DEFS $extra -Dmain=staged_tool_main "$@" "$OUT/obj/stage_input_main.o" \
    "$OUT/obj/lsan_off.o" -lm -o "$OUT/fuzz/$tool-staged"
}
build_staged bankpack "" "$S"/bankpack/*.c
build_staged ihxcheck "" "$S"/ihxcheck/*.c
build_staged makebin  "" "$S"/makebin/makebin.c
build_staged makecom  "" "$S"/makecom/*.c
build_staged romusage "-fno-sanitize=bool -I$S/romusage/src" "$S"/romusage/src/*.c

# png2asset (C++17): same source list as its Makefile (every .cpp in the dir).
P2A_SRCS=("$S"/png2asset/*.cpp)
# shellcheck disable=SC2086
$AFL_CXX $FUZZ_FLAGS -std=c++17 "${P2A_SRCS[@]}" "$OUT/obj/lsan_off.o" -o "$OUT/fuzz/png2asset"
# shellcheck disable=SC2086
$CXX $PLAIN_FLAGS -std=c++17 "${P2A_SRCS[@]}" -o "$OUT/plain/png2asset"

# gbcompress-zx0-decompress: in-process libFuzzer harness over the same salvador ZX0 decoder calls
# the CLI makes (see mayhem/harnesses/zx0_decompress_fuzzer.c for why it is not the CLI), plus its
# run-once -standalone reproducer. The zx0 sources are compiled with $SANITIZER_FLAGS too.
: "${LIB_FUZZING_ENGINE=-fsanitize=fuzzer}"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"
ZX0_SRCS=("$S"/gbcompress/zx0/*.c "$S"/gbcompress/zx0/libdivsufsort/*.c)
$CC $FUZZ_FLAGS -c "$SRC/mayhem/lsan_off.c" -o "$OUT/obj/lsan_off.lf.o"
$CC $FUZZ_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$OUT/obj/standalone_main.o"
# shellcheck disable=SC2086
$CC $FUZZ_FLAGS $COMMON_DEFS -I"$S/gbcompress" $LIB_FUZZING_ENGINE "$SRC/mayhem/harnesses/zx0_decompress_fuzzer.c" \
  "${ZX0_SRCS[@]}" "$OUT/obj/lsan_off.lf.o" -o "$OUT/fuzz/zx0_decompress_fuzzer"
# shellcheck disable=SC2086
$CC $FUZZ_FLAGS $COMMON_DEFS -I"$S/gbcompress" "$SRC/mayhem/harnesses/zx0_decompress_fuzzer.c" \
  "${ZX0_SRCS[@]}" "$OUT/obj/standalone_main.o" "$OUT/obj/lsan_off.lf.o" -o "$OUT/fuzz/zx0_decompress_fuzzer-standalone"

for t in bankpack gbcompress ihxcheck makebin makecom romusage png2hicolorgb png2asset; do
  [ -x "$OUT/fuzz/$t" ] && [ -x "$OUT/plain/$t" ] || { echo "missing $t" >&2; exit 1; }
done
for t in bankpack ihxcheck makebin makecom romusage; do
  [ -x "$OUT/fuzz/$t-staged" ] || { echo "missing $t-staged" >&2; exit 1; }
done
[ -x "$OUT/fuzz/zx0_decompress_fuzzer" ] && [ -x "$OUT/fuzz/zx0_decompress_fuzzer-standalone" ] || { echo "missing zx0_decompress_fuzzer" >&2; exit 1; }
echo "build.sh: built $(ls "$OUT/fuzz" | wc -l) fuzz + $(ls "$OUT/plain" | wc -l) oracle binaries"
