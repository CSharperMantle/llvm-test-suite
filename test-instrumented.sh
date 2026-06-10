#!/bin/bash

LLVM_PATH="${1:?Usage: \[LD=\{bfd,lld,mold\}\] \[LINK_JOBS=...\] \[PARALLEL_JOBS=...\] $0 <LLVM_PATH> \[BUILD_DIR\]}"
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
LINK_JOBS="${LINK_JOBS:-6}"
PARALLEL_JOBS="${PARALLEL_JOBS:-"$(nproc)"}"

export BUILD_DIR LLVM_PATH

cleanup() {
	echo 'XXX Restoring BOLTed files...' >&2
	while IFS='' read -r -d '' orig; do
		f="${orig%.orig}"
		mv "$f" "$f".bolt 2>/dev/null || true
		mv "$orig" "$f" 2>/dev/null || true
		rm -f "$f".bolt-converted 2>/dev/null || true
	done < <(find "$BUILD_DIR" -name '*.orig' -print0 2>/dev/null)
}
trap cleanup EXIT

cleanup
find "$BUILD_DIR" \( -name '*.bolt' -o -name '*.bolt-converted' -o -name '*.bolt-err' -o -name '*.bolt-instr' -o -name '*.prof.fdata*' \) -delete 2>/dev/null || true

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
ninja -C "$BUILD_DIR" || exit 3

"$LLVM_PATH"/bin/llvm-lit -sv -o results-s1.json "$BUILD_DIR" || {
	echo 'XXX Error: baseline tests failed; see results-s1.json' >&2
	exit 3
}

: >e.log

instrument_elf() {
	local f="$1"
	if ! file "$f" | grep -F 'ELF' >/dev/null 2>&1; then
		return 0
	fi
	if [ -e "$f".bolt-converted ]; then
		return 0
	fi
	printf 'XXX INSTRUMENT: %s\n' "$f" >&2
	if [ ! -e "$f".orig ]; then
		cp "$f" "$f".orig
	fi
	if stdout=$("$LLVM_PATH"/bin/llvm-bolt \
		"$f".orig \
		--instrument \
		--instrumentation-file="$(realpath "$f")".prof.fdata \
		--instrumentation-file-append-pid \
		-o "$f" 2>&1); then
		touch "$f".bolt-instr
	else
		printf 'XXX INSTRUMENT: %s\n%s\n' "$f" "$stdout" >"$f".bolt-err
		printf 'XXX Error: instrumentation failed for %s\n' "$f" >&2
		cp "$f".orig "$f"
	fi
}
export -f instrument_elf
find "$BUILD_DIR" -type f -executable \
	-not \( -name '*.orig' -o -name '*.stripped' -o -name '*.bolt' -o -path "$BUILD_DIR/tools/*" \) \
	-print0 |
	parallel -0 --line-buffer -j "$PARALLEL_JOBS" instrument_elf {}

if ! "$LLVM_PATH"/bin/llvm-lit -sv -o results-instr.json "$BUILD_DIR"; then
	echo 'XXX Warning: instrumented tests had failures; see results-instr.json' >&2
fi

bolt_with_profile() {
	local f="$1"
	if ! file "$f" | grep -F 'ELF' >/dev/null 2>&1; then
		return 0
	fi
	if [ -e "$f".bolt-converted ]; then
		return 0
	fi
	if [ ! -e "$f".bolt-instr ]; then
		printf 'XXX Error: %s was not instrumented, skipping\n' "$f" >&2
		return 0
	fi
	"$LLVM_PATH"/bin/merge-fdata "$f".prof.fdata.* -o "$f".prof.fdata 2>&1 || true
	if [ ! -s "$f".prof.fdata ]; then
		printf 'XXX Error: %s has no profile data\n' "$f" >&2
		printf 'XXX No profile data\n' >"$f".bolt-err
		return 0
	fi
	printf 'XXX BOLT: %s\n' "$f" >&2
	if stdout=$("$LLVM_PATH"/bin/llvm-bolt \
		"$f".orig \
		-o "$f" \
		--data "$f".prof.fdata \
		--reorder-functions=cdsort \
		--reorder-blocks=ext-tsp \
		--split-strategy=profile2 \
		--split-functions \
		--icp=all \
		--indirect-call-promotion=all \
		--simplify-rodata-loads \
		--peepholes=all \
		--hugify \
		--dyno-stats 2>&1); then
		touch "$f".bolt-converted
	else
		printf 'XXX BOLT: %s\n%s\n' "$f" "$stdout" >"$f".bolt-err
		printf 'XXX Error: %s\n' "$f" >&2
	fi
}
export -f bolt_with_profile
find "$BUILD_DIR" -type f -executable \
	-not \( -name '*.orig' -o -name '*.stripped' -o -name '*.bolt' -o -path "$BUILD_DIR/tools/*" \) \
	-print0 |
	parallel -0 --line-buffer -j "$PARALLEL_JOBS" bolt_with_profile {}

find "$BUILD_DIR" -name '*.bolt-err' -exec cat {} + >e.log 2>/dev/null || true
find "$BUILD_DIR" -name '*.bolt-err' -delete 2>/dev/null || true

"$LLVM_PATH"/bin/llvm-lit -sv -o results-s2.json "$BUILD_DIR"
