#!/usr/bin/env bash
#
# mayhem/test.sh — RUN this repo's OWN functional test suite (already built by mayhem/build.sh).
# exit 0 = pass. EDIT per repo. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}


# The oracle binaries were built by mayhem/build.sh with the project's normal flags.
P="$SRC/mayhem/out/plain"
M="$SRC/mayhem"
for t in bankpack gbcompress ihxcheck makebin makecom romusage png2asset; do
  [ -x "$P/$t" ] || { echo "test.sh: missing oracle binary $P/$t (build.sh did not run?)" >&2; emit_ctrf gbdk-support 0 1 0; exit 1; }
done
W="$(mktemp -d "${TMPDIR:-/tmp}/gbdk-test.XXXXXX")"
trap 'rm -rf "$W"' EXIT
cd "$W"

PASSED=0; FAILED=0
ok()   { echo "PASS: $1"; PASSED=$((PASSED+1)); }
bad()  { echo "FAIL: $1"; FAILED=$((FAILED+1)); }
check() { local name="$1"; shift; if ( "$@" ) >/dev/null 2>&1; then ok "$name"; else bad "$name"; fi; }
sha_is() { [ "$(sha256sum "$1" 2>/dev/null | cut -d' ' -f1)" = "$2" ]; }

# --- 1. png2asset: upstream's own golden-output suite (gbdk-support/png2asset/testing) -------------
# Regenerates every asset with the Makefile's option sets and diffs each file against testing/ref.
REF="$SRC/gbdk-support/png2asset/testing/ref"
make -s -C "$SRC/gbdk-support/png2asset/testing" generate-assets PNG2ASSET="$P/png2asset" OUTDIR="$W/p2a" >/dev/null 2>&1 || true
for f in "$REF"/*; do
  b="$(basename "$f")"
  if [ -f "$W/p2a/$b" ] && cmp -s "$f" "$W/p2a/$b"; then ok "png2asset ref/$b"; else bad "png2asset ref/$b"; fi
done

# --- 2. gbcompress: known-answer compressed output + round trip, for each algorithm -----------------
IN="$M/gbcompress-compress/testsuite/text.bin"
declare -A GOLD=( [gb]=98fb9236afeaa0d9c4b77fcf5402ae9688c0d68ff1c76c5a9d6925845aa0bb17
                  [zx0]=426c90fd8ff7a255f7d8bec90f437bf627527d1551b822d5851425cdfbf6ded5
                  [rle]=929ab7a513f1f5b219dc0c4c86041a1a3d5e9f335d54095970e395058c06399c )
for a in gb zx0 rle; do
  "$P/gbcompress" --alg=$a "$IN" "c.$a" >/dev/null 2>&1
  check "gbcompress --alg=$a known-answer output" sha_is "c.$a" "${GOLD[$a]}"
  "$P/gbcompress" -d --alg=$a "c.$a" "d.$a" >/dev/null 2>&1
  check "gbcompress --alg=$a round trip" cmp -s "d.$a" "$IN"
done
"$P/gbcompress" -d "$M/gbcompress-decompress/testsuite/text.gbc" d2.bin >/dev/null 2>&1
check "gbcompress -d committed stream" cmp -s d2.bin "$IN"
"$P/gbcompress" --cin --cout --varname=v "$M/gbcompress-csource/testsuite/demo.c" o.c >/dev/null 2>&1
check "gbcompress --cin --cout known-answer" sha_is o.c 5da39596a1c2a73dad2b02f2051560a3ab4022187ff7abedeebcfd60c44614f7
check "gbcompress --cout array header" grep -q '^const unsigned char v\[\] = {' o.c

# --- 3. makebin: ihx -> GB ROM (logo, header checksum), and .noi -> .sym ----------------------------
"$P/makebin" -Z -yo A "$M/makebin/testsuite/ok.ihx" o.gb >/dev/null 2>&1
check "makebin -Z ROM known-answer" sha_is o.gb 5bc1ee1a890bf879a5c7b7ccd373ee9852b50d93e5808c12a7e53423785134fb
check "makebin ihx data + logo at 0x100" test "$(od -An -tx1 -j256 -N8 o.gb | tr -d ' \n')" = "00010203ceed6666"
check "makebin header checksums" test "$(od -An -tx1 -j333 -N3 o.gb | tr -d ' \n')" = "56459b"
cp "$M/makebin-noi2sym/testsuite/a.noi" x.noi
"$P/makebin" -Z -yS x.noi x.gb >/dev/null 2>&1 || true
check "makebin -yS noi2sym known-answer" sha_is x.sym c2bc754f682356d20178db59a0fc98ee67e01806784e9cbdbce0b71ec9151b77
check "makebin -yS symbol line" grep -qx '00:0200 _main' x.sym

# --- 4. ihxcheck: valid file passes silently, overlapping writes are reported ------------------------
cp "$M/ihxcheck/testsuite/ok.ihx" ok.ihx; cp "$M/ihxcheck/testsuite/overlap.ihx" ov.ihx
check "ihxcheck clean file has no warnings" test -z "$("$P/ihxcheck" ok.ihx 2>&1)"
check "ihxcheck reports overlap" grep -q 'Multiple write of     2 bytes at 0x2 -> 0x3' <("$P/ihxcheck" ov.ihx 2>&1)

# --- 5. romusage: area/bank accounting for .noi, .map and .ihx inputs -------------------------------
cp "$M/romusage-noi/testsuite/a.noi" r.noi; cp "$M/romusage-map/testsuite/gbdk_map.txt" r.map
"$P/romusage" r.noi -a > noi.txt 2>&1 || true
check "romusage .noi ROM_0 totals" grep -Eq '^ROM_0 +0x0000 -> 0x3FFF +16384 +4864 +30% +11520 +70%' noi.txt
check "romusage .noi banked area" grep -Eq '^\+ _CODE_1 +0x4000 -> 0x47FF +2048' noi.txt
"$P/romusage" r.map -a > map.txt 2>&1 || true
check "romusage .map ROM_1 totals" grep -Eq '^ROM_1 +0x4000 -> 0x7FFF +16384 +2048 +12% +14336 +88%' map.txt
check "romusage rejects unknown extension" grep -q 'Incompatible file extension' <("$P/romusage" "$M/romusage-map/testsuite/gbdk_map.txt" 2>&1)

# --- 6. bankpack: auto-bank (255) area is assigned to bank 1 and rewritten ---------------------------
cp "$M/bankpack/testsuite/xl3_obj" in.o
"$P/bankpack" -mbc=5 -ext=.rel -path=./ in.o >/dev/null 2>&1
check "bankpack rewrote _CODE_255 -> _CODE_1" grep -qx 'A _CODE_1 size 100 flags 0 addr 0' in.rel
check "bankpack kept fixed area" grep -qx 'A _CODE size 0 flags 0 addr 0' in.rel

# --- 7. makecom: ROM + .noi -> MSX-DOS .com known-answer -------------------------------------------
cp "$M/makecom/testsuite/a.noi" m.noi
"$P/makecom" m.noi out.com >/dev/null 2>&1
check "makecom .com known-answer" sha_is out.com 1921ce2e152e26b82c69a727ddf9a06ca141f28820a5dee955cb67b6dc644196

cd "$SRC"
emit_ctrf "gbdk-support-golden" "$PASSED" "$FAILED" 0
