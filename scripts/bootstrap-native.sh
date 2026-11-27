#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CACHE="$ROOT/NativeBuild/downloads"
mkdir -p "$CACHE"
fetch() {
  local name="$1" url="$2" hash="$3"
  if [ ! -f "$CACHE/$name.zip" ]; then curl --fail --location --retry 3 "$url" -o "$CACHE/$name.zip"; fi
  python3 - "$CACHE/$name.zip" "$hash" <<'PY'
import hashlib,sys
path,expected=sys.argv[1:]
with open(path,'rb') as f: actual=hashlib.file_digest(f,'sha256').hexdigest() if hasattr(hashlib,'file_digest') else hashlib.sha256(f.read()).hexdigest()
if actual != expected: raise SystemExit('Checksum mismatch: '+path)
PY
  if [ ! -d "$CACHE/$name.xcframework" ]; then unzip -q "$CACHE/$name.zip" -d "$CACHE"; fi
}
fetch ssh2 https://github.com/apotocki/libssh2-iosx/releases/download/1.11.1.0/ssh2.xcframework.zip 1f1f7032da4525f1dac254a64fae0b4f3bc4be68b3434bf58e3a641d4138daa8
fetch crypto https://github.com/apotocki/openssl-iosx/releases/download/3.5.9.1/crypto.xcframework.zip b8d0c23713c52760dca27804516e179ae16bd9bed09c50bb02fc93df023f2f18
for pair in 'iphoneos ios-arm64' 'iphonesimulator ios-arm64_x86_64-simulator' 'macosx macos-arm64_x86_64'; do
  read -r sdk slice <<< "$pair"
  mkdir -p "$ROOT/Vendor/$sdk/include" "$ROOT/Vendor/$sdk/lib"
  for name in ssh2 crypto; do
    cp -R "$CACHE/$name.xcframework/$slice/Headers/." "$ROOT/Vendor/$sdk/include/"
    cp "$CACHE/$name.xcframework/$slice/lib$name.a" "$ROOT/Vendor/$sdk/lib/"
  done
 done
# Build static libopus.a for iphoneos, iphonesimulator, and macosx if not already present.
if [ ! -f "$ROOT/Vendor/iphoneos/lib/libopus.a" ] || [ ! -f "$ROOT/Vendor/iphonesimulator/lib/libopus.a" ] || [ ! -f "$ROOT/Vendor/macosx/lib/libopus.a" ]; then
  OPUS_SRC="$ROOT/NativeBuild/opus"
  if [ ! -d "$OPUS_SRC/.git" ]; then
    git clone --depth 1 --branch v1.5.2 https://github.com/xiph/opus.git "$OPUS_SRC"
  fi
  OPUS_BUILD="$ROOT/NativeBuild/opus-build"
  rm -rf "$OPUS_BUILD" && mkdir -p "$OPUS_BUILD"
  build_opus() {
    local name="$1" sysroot="$2" arch="$3" deploy="$4" sys_name="$5"
    local extra=()
    [ -n "$sys_name" ] && extra+=("-DCMAKE_SYSTEM_NAME=$sys_name")
    cmake -S "$OPUS_SRC" -B "$OPUS_BUILD/$name" "${extra[@]}" \
      -DCMAKE_OSX_SYSROOT="$sysroot" -DCMAKE_OSX_ARCHITECTURES="$arch" -DCMAKE_OSX_DEPLOYMENT_TARGET="$deploy" \
      -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DOPUS_BUILD_TESTING=OFF -DOPUS_BUILD_PROGRAMS=OFF \
      -DOPUS_INSTALL_PKG_CONFIG_MODULE=OFF -DOPUS_INSTALL_CMAKE_CONFIG_MODULE=OFF
    cmake --build "$OPUS_BUILD/$name" --parallel 8
  }
  build_opus iphoneos-arm64 iphoneos arm64 16.0 iOS
  build_opus iphonesimulator-arm64 iphonesimulator arm64 16.0 iOS
  build_opus iphonesimulator-x86_64 iphonesimulator x86_64 16.0 iOS
  build_opus macosx-arm64 macosx arm64 13.0 ""
  build_opus macosx-x86_64 macosx x86_64 13.0 ""
  for sdk in iphoneos iphonesimulator macosx; do
    mkdir -p "$ROOT/Vendor/$sdk/include/opus" "$ROOT/Vendor/$sdk/lib"
    cp "$OPUS_SRC"/include/opus*.h "$ROOT/Vendor/$sdk/include/opus/"
  done
  cp "$OPUS_BUILD/iphoneos-arm64/libopus.a" "$ROOT/Vendor/iphoneos/lib/libopus.a"
  lipo -create "$OPUS_BUILD/iphonesimulator-arm64/libopus.a" "$OPUS_BUILD/iphonesimulator-x86_64/libopus.a" -output "$ROOT/Vendor/iphonesimulator/lib/libopus.a"
  lipo -create "$OPUS_BUILD/macosx-arm64/libopus.a" "$OPUS_BUILD/macosx-x86_64/libopus.a" -output "$ROOT/Vendor/macosx/lib/libopus.a"
fi
printf 'Verified native libraries prepared in %s/Vendor\n' "$ROOT"
