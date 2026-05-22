#!/bin/bash

set -u

LLVM_PATH="$1"
if [[ -z "$LLVM_PATH" ]]; then
	echo "Usage: $0 <llvm_path>" >&2
	exit 1
fi
BUILD_DIR=build

cmake \
	-G Ninja \
	-B "$BUILD_DIR" \
	-DCMAKE_C_COMPILER="$LLVM_PATH"/bin/clang \
	-DCMAKE_CXX_COMPILER="$LLVM_PATH"/bin/clang++ \
	-DCMAKE_LINKER_TYPE=LLD \
	-DCMAKE_C_FLAGS='-Wl,-q' \
	-DCMAKE_CXX_FLAGS='-Wl,-q' \
	-DCMAKE_JOB_POOLS='link_pool=6' \
	-DCMAKE_JOB_POOL_LINK='link_pool' \
	-C cmake/caches/O3.cmake \
	. \
	|| exit 3
ninja -C "$BUILD_DIR" || exit 3

"$LLVM_PATH"/bin/llvm-lit -sv -o results-s1.json "$BUILD_DIR" || {
	echo 'XXX Error: baseline tests failed; see results-s1.json' >&2
	exit 3
}

truncate --size=0 e.log

i=0
while IFS='' read -r -d '' f
do
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
done < <(find "$BUILD_DIR" -type f -executable -not -name '*.orig' -not -name '*.stripped' -not -path "$BUILD_DIR/tools/*" -print0)

"$LLVM_PATH"/bin/llvm-lit -sv -o results-s2.json "$BUILD_DIR"

echo 'XXX Restoring BOLTed files...' >&2
while IFS='' read -r -d '' f
do
	if file "$f" | grep -F 'ELF' >/dev/null ; then
		((i++))
		if [ -e "$f".bolt-converted ]; then
			if [ -e "$f".orig ]; then
				rm -f "$f"
				mv "$f".orig "$f"
			else
				printf 'XXX Error: cannot find backup file: %s\n' "$f".orig >&2
			fi
		fi
	fi
done < <(find "$BUILD_DIR" -type f -executable -not -name '*.orig' -not -name '*.stripped' -not -path "$BUILD_DIR/tools/*" -print0)
