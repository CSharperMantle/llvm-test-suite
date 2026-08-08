#!/bin/bash
# shellcheck disable=SC2329
# vim: set tabstop=8 shiftwidth=8 softtabstop=8 noexpandtab:
# SPDX-License-Identifier: GPL-3.0-or-later

LLVM_PATH="${1:?Usage: \[LD=\{bfd,lld,mold\}\] \[BUILD_JOBS=...\] \[LINK_JOBS=...\] \[RUN_JOBS=...\] \[BOLT_JOBS=...\] $0 <LLVM_PATH> \[BUILD_DIR\]}"
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
RUN_JOBS="${RUN_JOBS:-"$(nproc)"}"
BOLT_JOBS="${BOLT_JOBS:-"$BUILD_JOBS"}"

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
rm -f results-*.json e.log || true

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

"$LLVM_PATH"/bin/llvm-lit -j "$RUN_JOBS" -sv -o results-s1.json "$BUILD_DIR"
s1_rc=$?

bolt_one_elf() {
	. ./source-bolt-flags.sh

	local f="$1"
	if ! file "$f" | grep -F 'ELF' >/dev/null 2>&1; then
		return 0
	fi
	if [ -e "$f".bolt-converted ]; then
		return 0
	fi
	printf 'XXX I BOLT: %s\n' "$f" >&2
	if [ ! -e "$f".orig ]; then
		cp "$f" "$f".orig
	fi
	if stdout="$("$LLVM_PATH"/bin/llvm-bolt \
		"$f".orig \
		-o "$f" \
		"${BOLT_SMOKE_FLAGS[@]}" 2>&1)"; then
		touch "$f".bolt-converted
	else
		printf 'XXX E BOLT: %s\n%s\n' "$f" "$stdout" >"$f".bolt-err
		printf 'XXX E BOLT: %s\n' "$f" >&2
	fi
}
export -f bolt_one_elf
find "$BUILD_DIR" -type f -executable \
	-not \( \
		-name '*.orig' \
		-o -name '*.stripped' \
		-o -name '*.bolt' \
		-o -path "$BUILD_DIR/tools/*" \
		-o -path "$BUILD_DIR/CMakeFiles/*" \
	\) \
	-print0 |
	parallel -0 --line-buffer -j "$BOLT_JOBS" bolt_one_elf {}

find "$BUILD_DIR" -name '*.bolt-err' -exec cat {} + >e.log 2>/dev/null || true
find "$BUILD_DIR" -name '*.bolt-err' -delete 2>/dev/null || true

"$LLVM_PATH"/bin/llvm-lit -j "$RUN_JOBS" -sv -o results-s2.json "$BUILD_DIR"
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

exit "$((s1_rc | s2_rc))"
