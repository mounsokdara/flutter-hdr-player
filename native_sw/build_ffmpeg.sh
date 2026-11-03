#!/usr/bin/env bash
# Builds a decode-only FFmpeg (LGPL, static, arm64-v8a): HEVC + H.264 decoders and nothing else.
set -euo pipefail
cd "$(dirname "$0")"

NDK="${ANDROID_NDK_LATEST_HOME:-${ANDROID_NDK_HOME:-}}"
if [ -z "$NDK" ] || [ ! -d "$NDK" ]; then echo "Android NDK not found (ANDROID_NDK_LATEST_HOME/ANDROID_NDK_HOME)"; exit 1; fi
TC="$NDK/toolchains/llvm/prebuilt/linux-x86_64"
API=26
OUT="$PWD/ffmpeg"
echo "NDK=$NDK"

rm -rf ffsrc "$OUT"
git clone --depth 1 --branch n7.1 https://github.com/FFmpeg/FFmpeg.git ffsrc
cd ffsrc

./configure \
  --prefix="$OUT" \
  --enable-cross-compile --target-os=android --arch=aarch64 --cpu=armv8-a \
  --cc="$TC/bin/aarch64-linux-android${API}-clang" \
  --cxx="$TC/bin/aarch64-linux-android${API}-clang++" \
  --ar="$TC/bin/llvm-ar" --nm="$TC/bin/llvm-nm" --ranlib="$TC/bin/llvm-ranlib" --strip="$TC/bin/llvm-strip" \
  --sysroot="$TC/sysroot" \
  --disable-everything --disable-autodetect --disable-programs --disable-doc --disable-debug --disable-network \
  --disable-avdevice --disable-avformat --disable-avfilter --disable-swscale --disable-swresample --disable-postproc \
  --enable-avcodec --enable-avutil \
  --enable-decoder=hevc --enable-decoder=h264 --enable-parser=hevc --enable-parser=h264 \
  --enable-pthreads --enable-neon --enable-asm \
  --enable-static --disable-shared --enable-pic \
  --extra-cflags="-O3 -fPIC"

make -j"$(nproc)"
make install
ls -la "$OUT/lib" "$OUT/include/libavcodec" | head -20
