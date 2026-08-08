#!/bin/bash
# shellcheck disable=SC2329
# vim: set tabstop=8 shiftwidth=8 softtabstop=8 noexpandtab:
# SPDX-License-Identifier: GPL-3.0-or-later

LLVM_PATH="${1:?Usage: \[LD=\{bfd,lld,mold\}\] \[BUILD_JOBS=...\] \[LINK_JOBS=...\] \[RUN_JOBS=...\] \[BOLT_JOBS=...\] \[PROFILE_JOBS=...\] \[PROFILE_RUNS=...\] $0 <LLVM_PATH> \[BUILD_DIR\]}"
BUILD_DIR="${2:-build}"
LD="${LD:-lld}"
case "$LD" in
bfd)
	CMAKE_LD=BFD
	;;
lld)
	CMAKE_LD=LLD
	;;
mold)
	CMAKE_LD=MOLD
	;;
*)
	echo 'Error: LD must be one of {bfd,lld,mold}' >&2
	exit 2
	;;
esac
BUILD_JOBS="${BUILD_JOBS:-"$(nproc)"}"
LINK_JOBS="${LINK_JOBS:-6}"
RUN_JOBS="${RUN_JOBS:-1}"
BOLT_JOBS="${BOLT_JOBS:-"$BUILD_JOBS"}"
PROFILE_JOBS="${PROFILE_JOBS:-"$(($(nproc) / 4))"}"
PROFILE_RUNS="${PROFILE_RUNS:-3}"

PERF_TESTS=(
	"$BUILD_DIR"/MultiSource/Applications/SIBsim4
	"$BUILD_DIR"/MultiSource/Applications/d
	"$BUILD_DIR"/MultiSource/Applications/oggenc
	"$BUILD_DIR"/MultiSource/Applications/hbd
	"$BUILD_DIR"/MultiSource/Applications/lambda-0.1.3
	"$BUILD_DIR"/MultiSource/Applications/lua
	"$BUILD_DIR"/MultiSource/Benchmarks/NPB-serial
	"$BUILD_DIR"/MultiSource/Benchmarks/PAQ8p
	"$BUILD_DIR"/MultiSource/Benchmarks/FreeBench/pcompress2
	"$BUILD_DIR"/MultiSource/Benchmarks/MallocBench/gs
	"$BUILD_DIR"/MultiSource/Benchmarks/McCat/12-IOtest
	"$BUILD_DIR"/MultiSource/Benchmarks/Olden/mst
	"$BUILD_DIR"/MultiSource/Benchmarks/Ptrdist/bc
	"$BUILD_DIR"/MultiSource/Benchmarks/mediabench/gsm
	"$BUILD_DIR"/MultiSource/Benchmarks/mediabench/jpeg
	"$BUILD_DIR"/MultiSource/Benchmarks/DOE-ProxyApps-C++/CLAMR
	"$BUILD_DIR"/MultiSource/Benchmarks/DOE-ProxyApps-C/CoMD
	"$BUILD_DIR"/MultiSource/Benchmarks/MiBench/automotive-susan
	"$BUILD_DIR"/MultiSource/Benchmarks/MiBench/consumer-jpeg
	"$BUILD_DIR"/MultiSource/Benchmarks/MiBench/consumer-typeset
	"$BUILD_DIR"/MultiSource/Benchmarks/MiBench/telecomm-gsm
	"$BUILD_DIR"/MultiSource/Benchmarks/MiBench/consumer-lame
	"$BUILD_DIR"/MultiSource/Benchmarks/Prolangs-C/bison
	"$BUILD_DIR"/MultiSource/Benchmarks/Prolangs-C/cdecl
	"$BUILD_DIR"/MicroBenchmarks/Builtins
	"$BUILD_DIR"/MicroBenchmarks/LCALS
	"$BUILD_DIR"/MicroBenchmarks/ImageProcessing/Dither
	"$BUILD_DIR"/MicroBenchmarks/ImageProcessing/BilateralFiltering
)

export BUILD_DIR LLVM_PATH

cleanup() {
	echo 'XXX I harness: Restoring BOLTed files...' >&2
	while IFS='' read -r -d '' orig; do
		f="${orig%.orig}"
		mv "$f" "$f".bolt 2>/dev/null || true
		mv "$orig" "$f" 2>/dev/null || true
		rm -f "$f".bolt-* 2>/dev/null || true
	done < <(find "$BUILD_DIR" -name '*.orig' -print0 2>/dev/null)
}
trap cleanup EXIT

_handle_signal() {
	trap '' INT TERM
	echo 'XXX I harness: Interrupt received, killing children...' >&2
	kill -- -"$$" 2>/dev/null || true
	exit $((128 + $1))
}
trap '_handle_signal $(kill -l INT)' INT
trap '_handle_signal $(kill -l TERM)' TERM

cleanup
find "$BUILD_DIR" \( -name '*.bolt' -o -name '*.bolt-*' -o -name '*.prof.fdata*' \) -delete 2>/dev/null || true
rm -f results-*.json e.log o.log || true

cmake \
	-G Ninja \
	-B "$BUILD_DIR" \
	-DCMAKE_C_COMPILER="$LLVM_PATH"/bin/clang \
	-DCMAKE_CXX_COMPILER="$LLVM_PATH"/bin/clang++ \
	-DCMAKE_LINKER_TYPE="$CMAKE_LD" \
	-DCMAKE_C_FLAGS="-Wl,-q $CFLAGS" \
	-DCMAKE_CXX_FLAGS="-Wl,-q $CXXFLAGS" \
	-DCMAKE_JOB_POOLS="link_pool=$LINK_JOBS" \
	-DCMAKE_JOB_POOL_LINK='link_pool' \
	-C cmake/caches/O3.cmake \
	. ||
	exit 3
ninja -j "$BUILD_JOBS" -C "$BUILD_DIR" || exit 3

"$LLVM_PATH"/bin/llvm-lit -j "$RUN_JOBS" --param timing=hyperfine -sv -o results-s1.json "${PERF_TESTS[@]}"
s1_rc=$?

instrument_elf() {
	. ./source-bolt-flags.sh

	local f="$1"
	if ! file "$f" | grep -F 'ELF' >/dev/null 2>&1; then
		return 0
	fi
	if [ -e "$f".bolt-converted ]; then
		return 0
	fi
	printf 'XXX I INSTRUMENT: %s\n' "$f" >&2
	if [ ! -e "$f".orig ]; then
		cp "$f" "$f".orig
	fi
	if stdout="$("$LLVM_PATH"/bin/llvm-bolt \
		"$f".orig \
		"${BOLT_INSTRUMENT_FLAGS[@]}" \
		--instrumentation-file="$(realpath "$f")".prof.fdata \
		-o "$f" 2>&1)"; then
		touch "$f".bolt-instr
		printf 'XXX I INSTRUMENT: %s\n%s\n' "$f" "$stdout" >>"$f".bolt-out
	else
		printf 'XXX E INSTRUMENT: %s\n%s\n' "$f" "$stdout" >>"$f".bolt-err
		printf 'XXX E INSTRUMENT: %s\n' "$f" >&2
		cp "$f".orig "$f"
	fi
}
export -f instrument_elf
find "${PERF_TESTS[@]}" -type f -executable \
	-not \( \
		-name '*.orig' \
		-o -name '*.stripped' \
		-o -name '*.bolt' \
		-o -path "$BUILD_DIR/tools/*" \
		-o -path "$BUILD_DIR/CMakeFiles/*" \
	\) \
	-print0 |
	parallel -0 --line-buffer -j "$BOLT_JOBS" instrument_elf {}

instr_rc=0
for i in $(seq 1 "$PROFILE_RUNS"); do
	printf 'XXX I harness: Instrumented (profiled) run: %d of %d\n' "$i" "$PROFILE_RUNS" >&2
	"$LLVM_PATH"/bin/llvm-lit -j "$PROFILE_JOBS" -q --progress-bar -o "results-instr-$i.json" "${PERF_TESTS[@]}"
	instr_rc="$((instr_rc | $?))"
done

bolt_with_profile() {
	. ./source-bolt-flags.sh

	local f="$1"
	if ! file "$f" | grep -F 'ELF' >/dev/null 2>&1; then
		return 0
	fi
	if [ -e "$f".bolt-converted ]; then
		return 0
	fi
	if [ ! -e "$f".bolt-instr ]; then
		printf 'XXX W harness: %s was not instrumented, skipping\n' "$f" >&2
		return 0
	fi
	if stdout="$("$LLVM_PATH"/bin/merge-fdata "$f".prof.fdata.* -o "$f".prof.fdata 2>&1)"; then
		touch "$f".bolt-fdata-merged
	else
		printf 'XXX E MERGE-FDATA: %s\n%s\n' "$f" "$stdout" >>"$f".bolt-err
		printf 'XXX E MERGE-FDATA: %s\n' "$f" >&2
		return 0
	fi
	printf 'XXX I BOLT: %s\n' "$f" >&2
	if stdout="$("$LLVM_PATH"/bin/llvm-bolt \
		"$f".orig \
		-o "$f" \
		--data "$f".prof.fdata \
		"${BOLT_FULL_FLAGS[@]}" 2>&1)"; then
		touch "$f".bolt-converted
		printf 'XXX I BOLT: %s\n%s\n' "$f" "$stdout" >>"$f".bolt-out
	else
		printf 'XXX E BOLT: %s\n%s\n' "$f" "$stdout" >>"$f".bolt-err
		printf 'XXX E BOLT: %s\n' "$f" >&2
	fi
}
export -f bolt_with_profile
find "${PERF_TESTS[@]}" -type f -executable \
	-not \( \
		-name '*.orig' \
		-o -name '*.stripped' \
		-o -name '*.bolt' \
		-o -path "$BUILD_DIR/tools/*" \
		-o -path "$BUILD_DIR/CMakeFiles/*" \
	\) \
	-print0 |
	parallel -0 --line-buffer -j "$BOLT_JOBS" bolt_with_profile {}

find "${PERF_TESTS[@]}" -name '*.bolt-err' -exec cat {} + >e.log 2>/dev/null || true
find "${PERF_TESTS[@]}" -name '*.bolt-out' -exec cat {} + >o.log 2>/dev/null || true
find "${PERF_TESTS[@]}" \( -name '*.bolt-err' -o -name '*.bolt-out' \) -delete 2>/dev/null || true

"$LLVM_PATH"/bin/llvm-lit -j "$RUN_JOBS" --param timing=hyperfine -sv -o results-s2.json "${PERF_TESTS[@]}"
s2_rc=$?

printf -- '---\n'
printf -- '\n'
printf -- 'Test Results\n'
printf -- '============\n'
printf -- '\n'
printf -- '\n'
printf -- 'Lit-tests\n'
printf -- '---------\n'
printf -- '\n'
printf -- '\t%s\tBaseline\n' "$([ $s1_rc -eq 0 ] && echo PASS || echo FAIL)"
printf -- '\t%s\tInstrument\n' "$([ $instr_rc -eq 0 ] && echo PASS || echo FAIL)"
printf -- '\t%s\tBOLT\n' "$([ $s2_rc -eq 0 ] && echo PASS || echo FAIL)"
printf -- '\n'
printf -- '\n'
printf -- 'Notable entries in e.log\n'
printf -- '------------------------\n'
printf -- '\n'
if [ -s e.log ]; then
	grep -E '^XXX (W|E) (harness|BOLT|INSTRUMENT):' e.log |
		while IFS= read -r line; do
			printf '\t%s\n' "$line"
		done
fi
printf -- '\n'
printf -- '---\n'

exit "$((s1_rc | instr_rc | s2_rc))"
