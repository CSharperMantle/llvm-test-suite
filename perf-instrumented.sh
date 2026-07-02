#!/bin/bash
# shellcheck disable=SC2329
# vim: set tabstop=8 shiftwidth=8 softtabstop=8 noexpandtab:

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
	echo 'XXX I harness: Restoring BOLTed files...' >&2
	while IFS='' read -r -d '' orig; do
		f="${orig%.orig}"
		mv "$f" "$f".bolt 2>/dev/null || true
		mv "$orig" "$f" 2>/dev/null || true
		rm -f "$f".bolt-* 2>/dev/null || true
	done < <(find "$BUILD_DIR" -name '*.orig' -print0 2>/dev/null)
}
trap cleanup EXIT

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
ninja -C "$BUILD_DIR" || exit 3

"$LLVM_PATH"/bin/llvm-lit --param timing=hyperfine -sv -o results-s1.json "$BUILD_DIR"
s1_rc=$?

instrument_elf() {
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
		--instrument \
		--instrument-load-profiles \
		--instrumentation-file="$(realpath "$f")".prof.fdata \
		--instrumentation-file-append-pid \
		-o "$f" 2>&1)"; then
		touch "$f".bolt-instr
		printf 'XXX I INSTRUMENT: %s\n%s\n' "$f" "$stdout" >"$f".bolt-out
	else
		printf 'XXX E INSTRUMENT: %s\n%s\n' "$f" "$stdout" >"$f".bolt-err
		printf 'XXX E INSTRUMENT: %s\n' "$f" >&2
		cp "$f".orig "$f"
	fi
}
export -f instrument_elf
find "$BUILD_DIR" -type f -executable \
	-not \( -name '*.orig' -o -name '*.stripped' -o -name '*.bolt' -o -path "$BUILD_DIR/tools/*" \) \
	-print0 |
	parallel -0 --line-buffer -j "$PARALLEL_JOBS" instrument_elf {}

"$LLVM_PATH"/bin/llvm-lit -sv -o results-instr.json "$BUILD_DIR"
instr_rc=$?

bolt_with_profile() {
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
		printf 'XXX E MERGE-FDATA: %s\n%s\n' "$f" "$stdout" >"$f".bolt-err
		printf 'XXX E MERGE-FDATA: %s\n' "$f" >&2
		return 0
	fi
	printf 'XXX I BOLT: %s\n' "$f" >&2
	if stdout="$("$LLVM_PATH"/bin/llvm-bolt \
		"$f".orig \
		-o "$f" \
		--data "$f".prof.fdata \
		--reorder-functions=cdsort \
		--reorder-blocks=ext-tsp \
		--split-strategy=profile2 \
		--split-functions \
		--icp=all \
		--icp-jump-tables-targets \
		--plt=hot \
		--simplify-rodata-loads \
		--frame-opt=all \
		--peepholes=all \
		--hugify \
		--huge-page-size="$(numfmt --from=auto '32Mi')" \
		--dyno-stats 2>&1)"; then
		touch "$f".bolt-converted
		printf 'XXX I BOLT: %s\n%s\n' "$f" "$stdout" >"$f".bolt-out
	else
		printf 'XXX E BOLT: %s\n%s\n' "$f" "$stdout" >"$f".bolt-err
		printf 'XXX E BOLT: %s\n' "$f" >&2
	fi
}
export -f bolt_with_profile
find "$BUILD_DIR" -type f -executable \
	-not \( -name '*.orig' -o -name '*.stripped' -o -name '*.bolt' -o -path "$BUILD_DIR/tools/*" \) \
	-print0 |
	parallel -0 --line-buffer -j "$PARALLEL_JOBS" bolt_with_profile {}

find "$BUILD_DIR" -name '*.bolt-err' -exec cat {} + >e.log 2>/dev/null || true
find "$BUILD_DIR" -name '*.bolt-out' -exec cat {} + >o.log 2>/dev/null || true
find "$BUILD_DIR" \( -name '*.bolt-err' -o -name '*.bolt-out' \) -delete 2>/dev/null || true

"$LLVM_PATH"/bin/llvm-lit --param timing=hyperfine -sv -o results-s2.json "$BUILD_DIR"
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
