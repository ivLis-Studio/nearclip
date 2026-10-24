#!/bin/bash
# Builds the Nearclip tailnet bridge (embedded Tailscale) for every app.
#
#   tailnet/build.sh [notices] [apple] [android] [windows] [desktop] [testcontrol] [all]
#
#   notices      tailnet/notices/THIRD_PARTY_NOTICES.txt               (licenses of everything linked in; committed)
#   apple        apple/NearclipKit/Binaries/NCTailnet.xcframework   (macOS universal, iOS, iOS Simulator)
#   android      android/app/src/main/jniLibs/<abi>/libnctailnet.so (arm64-v8a, armeabi-v7a, x86_64; JNI)
#   windows      windows/native/win-<arch>/nctailnet.dll           (x64, arm64)
#   desktop      tailnet/out/desktop/libnctailnet.dylib             (this Mac; JNI + C ABI, for the test CLIs)
#   testcontrol  tailnet/out/nctestcontrol                          (throwaway control server for tests)
#
# Requirements: Go (see go.mod), Xcode, the Android NDK (ANDROID_NDK_HOME or the newest one in the
# default SDK), llvm-mingw for Windows (LLVM_MINGW, default ~/Library/Caches/nearclip-toolchains/...).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TN="$ROOT/tailnet"
OUT="$TN/out"
cd "$TN"
export CGO_ENABLED=1

# Old outputs are moved aside (never deleted in place).
retire() {
    if [ -e "$1" ]; then
        local bin
        bin="$(mktemp -d "${TMPDIR:-/tmp}/nctailnet-old.XXXXXX")"
        mv "$1" "$bin/"
    fi
}

apple() {
    local work="$OUT/apple"
    retire "$work"
    mkdir -p "$work/include"
    cp include/nctailnet.h include/module.modulemap "$work/include/"
    archive() { # goos goarch sdk clang-target out
        local sdkpath cc
        sdkpath="$(xcrun --sdk "$3" --show-sdk-path)"
        cc="$(xcrun --sdk "$3" --find clang)"
        mkdir -p "$(dirname "$5")"
        echo "  $1/$2 ($4)"
        env GOOS="$1" GOARCH="$2" CC="$cc" \
            CGO_CFLAGS="-isysroot $sdkpath -target $4 -O2" CGO_LDFLAGS="-isysroot $sdkpath -target $4" \
            go build -trimpath -ldflags=-w -buildmode=c-archive -o "$5" ./capi
        retire "${5%.a}.h"
    }
    archive darwin arm64 macosx arm64-apple-macos14.0 "$work/macos-arm64/libNCTailnet.a"
    archive darwin amd64 macosx x86_64-apple-macos14.0 "$work/macos-x86_64/libNCTailnet.a"
    archive ios arm64 iphoneos arm64-apple-ios17.0 "$work/ios/libNCTailnet.a"
    archive ios arm64 iphonesimulator arm64-apple-ios17.0-simulator "$work/iossim-arm64/libNCTailnet.a"
    archive ios amd64 iphonesimulator x86_64-apple-ios17.0-simulator "$work/iossim-x86_64/libNCTailnet.a"
    mkdir -p "$work/macos" "$work/iossim"
    lipo -create -output "$work/macos/libNCTailnet.a" "$work/macos-arm64/libNCTailnet.a" "$work/macos-x86_64/libNCTailnet.a"
    lipo -create -output "$work/iossim/libNCTailnet.a" "$work/iossim-arm64/libNCTailnet.a" "$work/iossim-x86_64/libNCTailnet.a"
    local dest="$ROOT/apple/NearclipKit/Binaries/NCTailnet.xcframework"
    retire "$dest"
    mkdir -p "$(dirname "$dest")"
    xcodebuild -create-xcframework \
        -library "$work/macos/libNCTailnet.a" -headers "$work/include" \
        -library "$work/ios/libNCTailnet.a" -headers "$work/include" \
        -library "$work/iossim/libNCTailnet.a" -headers "$work/include" \
        -output "$dest" >/dev/null
    echo "apple: $dest"
}

android() {
    local ndk="${ANDROID_NDK_HOME:-}"
    if [ -z "$ndk" ]; then
        ndk="$(ls -d "$HOME/Library/Android/sdk/ndk/"* 2>/dev/null | sort -V | tail -1)"
    fi
    [ -d "$ndk" ] || { echo "Android NDK not found (set ANDROID_NDK_HOME)" >&2; exit 1; }
    local tc
    tc="$(ls -d "$ndk"/toolchains/llvm/prebuilt/*/bin | head -1)"
    local api=26
    for abi in arm64-v8a armeabi-v7a x86_64; do
        local goarch cc goarm=""
        case $abi in
            arm64-v8a) goarch=arm64; cc="aarch64-linux-android$api-clang" ;;
            armeabi-v7a) goarch=arm; goarm=7; cc="armv7a-linux-androideabi$api-clang" ;;
            x86_64) goarch=amd64; cc="x86_64-linux-android$api-clang" ;;
        esac
        local out="$ROOT/android/app/src/main/jniLibs/$abi/libnctailnet.so"
        mkdir -p "$(dirname "$out")"
        echo "  android/$abi"
        env GOOS=android GOARCH=$goarch GOARM=$goarm CC="$tc/$cc" CGO_CFLAGS="-DNCTN_JNI -O2" \
            go build -trimpath -buildmode=c-shared \
            -ldflags="-s -w -extldflags=-Wl,-soname,libnctailnet.so,-z,max-page-size=16384" \
            -o "$out" ./capi
        retire "${out%.so}.h"
    done
    echo "android: $ROOT/android/app/src/main/jniLibs"
}

windows() {
    local mingw="${LLVM_MINGW:-$HOME/Library/Caches/nearclip-toolchains/llvm-mingw-20261020-ucrt-macos-universal}"
    [ -x "$mingw/bin/aarch64-w64-mingw32-clang" ] || { echo "llvm-mingw not found (set LLVM_MINGW)" >&2; exit 1; }
    for arch in x64 arm64; do
        local goarch cc
        case $arch in
            x64) goarch=amd64; cc=x86_64-w64-mingw32-clang ;;
            arm64) goarch=arm64; cc=aarch64-w64-mingw32-clang ;;
        esac
        local out="$ROOT/windows/native/win-$arch/nctailnet.dll"
        mkdir -p "$(dirname "$out")"
        echo "  windows/$arch"
        env GOOS=windows GOARCH=$goarch CC="$mingw/bin/$cc" CGO_CFLAGS="-O2" \
            go build -trimpath -buildmode=c-shared -ldflags="-s -w" -o "$out" ./capi
        retire "${out%.dll}.h"
    done
    echo "windows: $ROOT/windows/native"
}

desktop() {
    local jdk="${JAVA_HOME:-/Applications/Android Studio.app/Contents/jbr/Contents/Home}"
    local out="$OUT/desktop/libnctailnet.dylib"
    mkdir -p "$(dirname "$out")"
    env CGO_CFLAGS="-DNCTN_JNI -O2 -I$jdk/include -I$jdk/include/darwin" \
        go build -trimpath -buildmode=c-shared \
        -ldflags="-s -w -extldflags=-Wl,-install_name,@rpath/libnctailnet.dylib" -o "$out" ./capi
    retire "${out%.dylib}.h"
    echo "desktop: $out"
}

testcontrol() {
    mkdir -p "$OUT"
    go build -trimpath -o "$OUT/nctestcontrol" ./cmd/nctestcontrol
    echo "testcontrol: $OUT/nctestcontrol"
}

# The license files at the top of a module (or of GOROOT).
license_files() {
    find "$1" -maxdepth 1 -type f \( -iname 'LICEN[CS]E*' -o -iname 'COPYING*' -o -iname 'NOTICE*' -o -iname 'PATENTS*' \) | sort
}

# Go's own license; Homebrew keeps LICENSE one level above GOROOT.
go_license_files() {
    [ -f "$1/LICENSE" ] || { [ -f "$1/../LICENSE" ] && echo "$(cd "$1/.." && pwd)/LICENSE"; }
    license_files "$1"
}

license_kind() {
    local f="$1"
    if [ -z "$f" ]; then echo "(no license file)"
    elif grep -q "Apache License" "$f" && grep -q "Version 2.0" "$f"; then echo "Apache-2.0"
    elif grep -qi "Permission is hereby granted, free of charge" "$f"; then echo "MIT"
    elif grep -q "Redistribution and use in source and binary forms" "$f"; then
        if grep -qiE "Neither the name|names of (its|the) contributors" "$f"; then echo "BSD-3-Clause"; else echo "BSD-2-Clause"; fi
    elif grep -qE "Permission to use, copy, modify, and(/or)? distribute" "$f"; then echo "ISC"
    elif grep -q "Mozilla Public License" "$f"; then echo "MPL-2.0"
    else echo "see text"; fi
}

# Licenses of everything linked into the bridge on any platform: the Go runtime and standard library and every
# Go module. The apps show this file under their open-source licenses.
notices() {
    local out="$TN/notices/THIRD_PARTY_NOTICES.txt" paths goroot rule
    paths="$(for t in darwin/arm64 darwin/amd64 ios/arm64 android/arm64 android/arm android/amd64 windows/amd64 windows/arm64; do
        GOOS="${t%/*}" GOARCH="${t#*/}" go list -deps -f '{{with .Module}}{{if not .Main}}{{.Path}}{{end}}{{end}}' ./capi
    done | sort -u)"
    goroot="$(go env GOROOT)"
    rule="$(printf '=%.0s' {1..100})"
    mkdir -p "$(dirname "$out")"
    {
        echo "Nearclip: third-party notices for remote connection (the embedded Tailscale node)"
        echo
        echo "The Nearclip apps for macOS, iOS, Android and Windows include a library built from tailnet/ in the Nearclip"
        echo "source code. It contains the Go runtime and standard library and the Go modules listed below. Each one is"
        echo "followed by its license as published by its authors."
        echo "Generated by tailnet/build.sh notices; do not edit."
        echo
        printf '  %-72s %s\n' "Go (runtime and standard library) $(go env GOVERSION)" "$(license_kind "$(go_license_files "$goroot" | head -1)")"
        # shellcheck disable=SC2086
        go list -m -f '{{.Path}} {{.Version}} {{.Dir}}' $paths | while read -r path version dir; do
            printf '  %-72s %s\n' "$path $version" "$(license_kind "$(license_files "$dir" | head -1)")"
        done
        { echo "Go $(go env GOVERSION) $goroot"; go list -m -f '{{.Path}} {{.Version}} {{.Dir}}' $paths; } |
        while read -r path version dir; do
            echo
            echo "$rule"
            echo "$path $version"
            echo "$rule"
            if [ "$path" = Go ]; then go_license_files "$dir"; else license_files "$dir"; fi | while read -r f; do
                echo
                echo "--- $(basename "$f")"
                echo
                cat "$f"
            done
        done
    } > "$out.tmp"
    mv "$out.tmp" "$out"
    echo "notices: $out ($(echo "$paths" | wc -l | tr -d ' ') modules)"
}

[ $# -gt 0 ] || set -- all
for target in "$@"; do
    case $target in
        notices|apple|android|windows|desktop|testcontrol) "$target" ;;
        all) notices; apple; android; windows; desktop; testcontrol ;;
        *) echo "unknown target: $target" >&2; exit 2 ;;
    esac
done
