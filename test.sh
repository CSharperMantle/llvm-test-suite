#!/bin/bash

LLVM_PATH="${1:?Usage: \[LD=\{bfd,lld,mold\}\] \[LINK_JOBS=...\] $0 <LLVM_PATH> \[BUILD_DIR\]}"
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
		echo 'Error: $LD must be one of {bfd,lld,mold}' >&2
		exit 2
		;;
esac
LINK_JOBS="${LINK_JOBS:-6}"

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
find "$BUILD_DIR" \( -name '*.bolt' -o -name '*.bolt-converted' \) -delete 2>/dev/null || true

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
	. \
	|| exit 3
ninja -C "$BUILD_DIR" || exit 3

"$LLVM_PATH"/bin/llvm-lit -sv -o results-s1.json "$BUILD_DIR" || {
	echo 'XXX Error: baseline tests failed; see results-s1.json' >&2
	exit 3
}

: >e.log

i=0
while IFS='' read -r -d '' f; do
	if file "$f" | grep -F 'ELF' >/dev/null ; then
		((i++))
		if [ ! -e "$f".bolt-converted ]; then
			printf 'XXX [%d] BOLT: %s\n' "$i" "$f" >&2
			if [ ! -e "$f".orig ]; then
				cp "$f" "$f".orig
			fi
			if stdout=$("$LLVM_PATH"/bin/llvm-bolt \
				"$f".orig \
				-o "$f" \
				-reorder-functions=hfsort \
				-split-functions \
				-split-all-cold 2>&1) ;
			then
				touch "$f".bolt-converted
			else
				printf 'XXX Error: %s\n%s\n\n' "$f" "$stdout" >&2
				printf -- '--- Error: %s ---\n%s\n\n' "$f" "$stdout" >> e.log
			fi
		fi
	fi
done < <(find "$BUILD_DIR" -type f -executable -not \( -name '*.orig' -o -name '*.stripped' -o -name '*.bolt' -o -path "$BUILD_DIR/tools/*" \) -print0)

"$LLVM_PATH"/bin/llvm-lit -sv -o results-s2.json "$BUILD_DIR"
