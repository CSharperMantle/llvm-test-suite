#!/bin/bash

LLVM_PATH="$1"

if [[ -z "$LLVM_PATH" ]]; then
  echo "Usage: $0 <llvm_path>"
  exit 1
fi

BUILD_DIR=build

rm -rf ${BUILD_DIR}
mkdir ${BUILD_DIR} && cd ${BUILD_DIR}

cmake \
  -DCMAKE_C_COMPILER=$LLVM_PATH/bin/clang \
  -DCMAKE_CXX_COMPILER=$LLVM_PATH/bin/clang++ \
  -C../cmake/caches/O3.cmake \
  ../ \
  -DCMAKE_C_FLAGS="-O3 -Wl,-q -fuse-ld=lld" \
  -DCMAKE_CXX_FLAGS="-O3 -Wl,-q -fuse-ld=lld"

make -j$(nproc) VERBOSE=1
$LLVM_PATH/bin/llvm-lit -v -j $(nproc) -o ../results-s1.json .

cd ..
echo "" > e.log

i=0
for f in `find ${BUILD_DIR} -type f -executable -not -name "*.orig" -not -name "*.stripped" -not -path "${BUILD_DIR}/tools/*" `; do
  if file $f | grep "ELF" > /dev/null ; then
    ((i++))
    if true; then
      if [ ! -e ${f}.bolt ]; then
        echo -e "\n\nXXX [$i] BOLT: ${f}\n"
        if [ ! -e ${f}.orig ]; then
          cp ${f}{,.orig} -v
        fi
        echo -e "\n\n"
        $LLVM_PATH/bin/llvm-bolt ${f}.orig -o ${f} --no-threads -reorder-functions=hfsort -split-functions -split-all-cold
        if [ $? -ne 0 ]; then
          echo -e "\n\nXXX Error: ${f}\n"
          echo "Error: ${f}" >> e.log
        else
          touch ${f}.bolt
        fi
      fi
    else
      rm -f ${f} -v
      rm -f ${f}.orig -v
      rm -f ${f}.bolt -v
    fi
  fi
done

cd ${BUILD_DIR}
$LLVM_PATH/bin/llvm-lit -v -j $(nproc) -o ../results-s2.json .
