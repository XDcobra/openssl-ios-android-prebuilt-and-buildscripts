#!/bin/bash
set -e

IOS_MIN_VERSION="12.0"
OUT_DIR="$(pwd)/build/ios"
mkdir -p "$OUT_DIR"

echo "Building iOS binaries (Min iOS $IOS_MIN_VERSION)..."

cd openssl

# Helper function to compile and combine archives
build_and_combine() {
    local TARGET_NAME=$1
    local SDK_NAME=$2
    local OUTPUT_DIR_NAME=$3
    local EXTRA_ARGS=$4

    echo "============================================="
    echo "Building for $TARGET_NAME ($OUTPUT_DIR_NAME)..."
    echo "============================================="

    if [ -f Makefile ]; then
        make clean || true
    fi
    
    # Set proper architectures for simulator platforms
    if [ -n "$EXTRA_ARGS" ]; then
        export CC="clang $EXTRA_ARGS"
        export CXX="clang++ $EXTRA_ARGS"
    else
        unset CC
        unset CXX
    fi

    # no-shared produces static libraries (.a) exclusively
    ./Configure $TARGET_NAME no-shared -fembed-bitcode \
        -miphoneos-version-min=$IOS_MIN_VERSION \
        -mios-simulator-version-min=$IOS_MIN_VERSION

    make -j$(sysctl -n hw.ncpu 2>/dev/null || nproc)

    local TARGET_OUT_DIR="$OUT_DIR/$OUTPUT_DIR_NAME"
    mkdir -p "$TARGET_OUT_DIR"
    
    # Backup generated headers
    cp -r include/openssl "$TARGET_OUT_DIR/"
    
    # Combine individual static libraries into a single fat archive
    echo "Combining libssl.a and libcrypto.a into libopenssl.a via libtool..."
    libtool -static -o "$TARGET_OUT_DIR/libopenssl.a" libcrypto.a libssl.a
}

# 1. Device (arm64)
# ios64-xcrun explicitly targets physical devices (arm64)
build_and_combine "ios64-xcrun" "iphoneos" "device" ""

# 2. Simulator (arm64)
build_and_combine "iossimulator-xcrun" "iphonesimulator" "sim_arm64" "-arch arm64"

# 3. Simulator (x86_64)
build_and_combine "iossimulator-xcrun" "iphonesimulator" "sim_x86_64" "-arch x86_64"

unset CC
unset CXX

# 4. Create Universal Simulator Binary (arm64 + x86_64)
echo "============================================="
echo "Creating Universal Binary for Simulator (lipo)..."
echo "============================================="
mkdir -p "$OUT_DIR/simulator"
lipo -create -output "$OUT_DIR/simulator/libopenssl.a" \
    "$OUT_DIR/sim_arm64/libopenssl.a" \
    "$OUT_DIR/sim_x86_64/libopenssl.a"

# 5. Combine into XCFramework
echo "============================================="
echo "Creating openssl.xcframework..."
echo "============================================="
XCFRAMEWORK_DIR="$OUT_DIR/openssl.xcframework"
rm -rf "$XCFRAMEWORK_DIR"
xcodebuild -create-xcframework \
    -library "$OUT_DIR/device/libopenssl.a" -headers "$OUT_DIR/device/openssl" \
    -library "$OUT_DIR/simulator/libopenssl.a" -headers "$OUT_DIR/device/openssl" \
    -output "$XCFRAMEWORK_DIR"

echo "============================================="
echo "iOS build completed!"
echo "Final xcframework is located in: $XCFRAMEWORK_DIR"
echo "============================================="
