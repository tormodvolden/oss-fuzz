#!/bin/bash -eu
# Copyright 2021 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
################################################################################

# This script is supposed to be compatible with OSS-Fuzz, i.e. it has to use
# environment variables like $CC, $CFLAGS, $OUT, link the fuzz targets with CXX
# (even though the project is written in C) and so on:
# https://google.github.io/oss-fuzz/getting-started/new-project-guide/#buildsh

# It can be used to build and run the fuzz targets using Docker and the images
# provided by the OSS-Fuzz project: https://google.github.io/oss-fuzz/advanced-topics/reproducing/#building-using-docker

# It can also be used to build and run the fuzz target locally without Docker.
# After installing clang and the build dependencies of libelf by running something
# like `dnf build-dep elfutils-devel` on Fedora or `apt-get build-dep libelf-dev`
# on Debian/Ubuntu, the following commands should be run:
#
#  $ git clone https://github.com/google/oss-fuzz
#  $ cd oss-fuzz/projects/elfutils
#  $ git clone git://sourceware.org/git/elfutils.git
#  $ ./build.sh
#  $ unzip -d CORPUS fuzz-dwfl-core_seed_corpus.zip
#  $ ./out/fuzz-dwfl-core CORPUS/

set -eux

SANITIZER=${SANITIZER:-address}
flags="-O1 -fno-omit-frame-pointer -g -DFUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION -fsanitize=$SANITIZER -fsanitize=fuzzer-no-link"

export CC=${CC:-clang}
export CFLAGS=${CFLAGS:-$flags}

export CXX=${CXX:-clang++}
export CXXFLAGS=${CXXFLAGS:-$flags}

export SRC=${SRC:-$(realpath -- $(dirname -- "$0"))}
export OUT=${OUT:-"$SRC/out"}
mkdir -p "$OUT"

export LIB_FUZZING_ENGINE=${LIB_FUZZING_ENGINE:--fsanitize=fuzzer}

cd "$SRC/elfutils"

# ASan isn't compatible with -Wl,--no-undefined: https://github.com/google/sanitizers/issues/380
find -name Makefile.am | xargs sed -i 's/,--no-undefined//'

# ASan isn't compatible with -Wl,-z,defs either:
# https://clang.llvm.org/docs/AddressSanitizer.html#usage
sed -i 's/^\(ZDEFS_LDFLAGS=\).*/\1/' configure.ac

if [[ "$SANITIZER" == undefined ]]; then
    additional_ubsan_checks=alignment
    UBSAN_FLAGS="-fsanitize=$additional_ubsan_checks -fno-sanitize-recover=$additional_ubsan_checks"
    CFLAGS="$CFLAGS $UBSAN_FLAGS"
    CXXFLAGS="$CXXFLAGS $UBSAN_FLAGS"

    # That's basicaly what --enable-sanitize-undefined does to turn off unaligned access
    # elfutils heavily relies on on i386/x86_64 but without changing compiler flags along the way
    sed -i 's/\(check_undefined_val\)=[0-9]/\1=1/' configure.ac
fi

if [[ "$SANITIZER" == memory ]]; then
    CFLAGS+=" -U_FORTIFY_SOURCE"
    CXXFLAGS+=" -U_FORTIFY_SOURCE"
fi

autoreconf -i -f
if ! ./configure --enable-maintainer-mode --disable-debuginfod --disable-libdebuginfod \
            --without-bzlib --without-lzma --without-zstd \
	    CC="$CC" CFLAGS="-Wno-error $CFLAGS" CXX="-Wno-error $CXX" CXXFLAGS="$CXXFLAGS" LDFLAGS="$CFLAGS"; then
    cat config.log
    exit 1
fi

ASAN_OPTIONS=detect_leaks=0 make -j$(nproc) V=1

# External dependencies used by the fuzz targets have to be built
# with MSan explicitly to avoid bogus "security" bug reports like
# https://bugs.chromium.org/p/oss-fuzz/issues/detail?id=45630,
# https://bugs.chromium.org/p/oss-fuzz/issues/detail?id=45631 and
# https://bugs.chromium.org/p/oss-fuzz/issues/detail?id=45633
zlib="-l:libz.a"
if [[ "$SANITIZER" == memory ]]; then
    git clone https://github.com/madler/zlib
    pushd zlib
    git checkout v1.2.11
    if ! ./configure --static; then
        cat configure.log
        exit 1
    fi
    make -j$(nproc) V=1
    popd
    zlib=zlib/libz.a
fi

# When new fuzz targets are added it usually makes sense to notify the maintainers of
# the elfutils project using the mailing list: elfutils-devel@sourceware.org. There
# fuzz targets can be reviewed properly (to make sure they don't fail to compile
# with -Werror for example), their names can be chosen accordingly (so as not to spam
# the mailing list with bogus bug reports that are opened and closed once they are renamed)
# and so on. Also since a lot of bug reports coming out of the blue aren't exactly helpful
# fuzz targets should probably be added one at a time to make it easier to keep track
# of them.
$CC $CFLAGS \
	-D_GNU_SOURCE -DHAVE_CONFIG_H \
	-I. -I./lib -I./libelf -I./libebl -I./libdw -I./libdwelf -I./libdwfl -I./libasm \
	-c "$SRC/fuzz-dwfl-core.c" -o fuzz-dwfl-core.o
$CXX $CXXFLAGS $LIB_FUZZING_ENGINE fuzz-dwfl-core.o \
	./libdw/libdw.a ./libelf/libelf.a "$zlib" \
	-o "$OUT/fuzz-dwfl-core"

$CC $CFLAGS \
  -D_GNU_SOURCE -DHAVE_CONFIG_H \
  -I. -I./lib -I./libelf -I./libebl -I./libdw -I./libdwelf -I./libdwfl -I./libasm \
  -c "$SRC/fuzz-libelf.c" -o fuzz-libelf.o
$CXX $CXXFLAGS $LIB_FUZZING_ENGINE fuzz-libelf.o \
	./libasm/libasm.a ./libebl/libebl.a ./backends/libebl_backends.a ./libcpu/libcpu.a \
  ./libdw/libdw.a ./libelf/libelf.a ./lib/libeu.a "$zlib" \
	-o "$OUT/fuzz-libelf"

$CC $CFLAGS \
  -D_GNU_SOURCE -DHAVE_CONFIG_H \
  -I. -I./lib -I./libelf -I./libebl -I./libdw -I./libdwelf -I./libdwfl -I./libasm \
  -c "$SRC/fuzz-libdwfl.c" -o fuzz-libdwfl.o
$CXX $CXXFLAGS $LIB_FUZZING_ENGINE fuzz-libdwfl.o \
	./libasm/libasm.a ./libebl/libebl.a ./backends/libebl_backends.a ./libcpu/libcpu.a \
  ./libdw/libdw.a ./libelf/libelf.a ./lib/libeu.a "$zlib" \
	-o "$OUT/fuzz-libdwfl"

# Corpus
cp "$SRC/fuzz-dwfl-core_seed_corpus.zip" "$OUT"
