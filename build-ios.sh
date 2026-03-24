#!/bin/bash
set -e

IOS_MIN_VERSION="12.0"
OUT_DIR="$(pwd)/build/ios"
mkdir -p "$OUT_DIR"

find_first_existing_file() {
    for candidate in "$@"; do
        if [ -f "$candidate" ]; then
            echo "$candidate"
            return 0
        fi
    done
    return 1
}

OPENSSL_LICENSE_SOURCE="$(find_first_existing_file \
    "$(pwd)/LICENSE.txt" \
    "$(pwd)/openssl/LICENSE.txt" \
    "$(pwd)/openssl/LICENSE")"

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
    
    local SDK_PATH=$(xcrun -sdk $SDK_NAME --show-sdk-path)
    local PLATFORM_FLAGS=""
    
    if [[ "$SDK_NAME" == "iphonesimulator" ]]; then
        PLATFORM_FLAGS="-mios-simulator-version-min=$IOS_MIN_VERSION"
        # For simulator binaries to be correctly tagged, we often need the target triple
        if [[ "$EXTRA_ARGS" == *"-arch arm64"* ]]; then
            PLATFORM_FLAGS="$PLATFORM_FLAGS -target arm64-apple-ios$IOS_MIN_VERSION-simulator"
        elif [[ "$EXTRA_ARGS" == *"-arch x86_64"* ]]; then
            PLATFORM_FLAGS="$PLATFORM_FLAGS -target x86_64-apple-ios$IOS_MIN_VERSION-simulator"
        fi
    else
        PLATFORM_FLAGS="-miphoneos-version-min=$IOS_MIN_VERSION"
    fi

    # Set compiler with explicit sysroot and architecture
    export CC="clang -isysroot $SDK_PATH $EXTRA_ARGS $PLATFORM_FLAGS"
    export CXX="clang++ -isysroot $SDK_PATH $EXTRA_ARGS $PLATFORM_FLAGS"

    # Important: OpenSSL 3's Configure can be picky. We pass the flags via CC/CXX.
    ./Configure $TARGET_NAME no-shared

    make -j$(sysctl -n hw.ncpu 2>/dev/null || nproc)

    local TARGET_OUT_DIR="$OUT_DIR/$OUTPUT_DIR_NAME"
    mkdir -p "$TARGET_OUT_DIR"
    
    # Backup generated headers
    cp -r include/openssl "$TARGET_OUT_DIR/"
    
    # Combine libssl.a and libcrypto.a into a single static library
    echo "Combining libssl.a and libcrypto.a into libopenssl.a via libtool..."
    libtool -static -o "$TARGET_OUT_DIR/libopenssl.a" libcrypto.a libssl.a
}

# 1. Device (arm64)
# ios64-xcrun targets physical devices
build_and_combine "ios64-xcrun" "iphoneos" "device" "-arch arm64"

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

# 5. Create XCFramework
echo "============================================="
echo "Creating openssl.xcframework..."
echo "============================================="
XCFRAMEWORK_DIR="$OUT_DIR/openssl.xcframework"
rm -rf "$XCFRAMEWORK_DIR"
xcodebuild -create-xcframework \
    -library "$OUT_DIR/device/libopenssl.a" -headers "$OUT_DIR/device/openssl" \
    -library "$OUT_DIR/simulator/libopenssl.a" -headers "$OUT_DIR/device/openssl" \
    -output "$XCFRAMEWORK_DIR"

if [ -z "$OPENSSL_LICENSE_SOURCE" ] || [ ! -f "$OPENSSL_LICENSE_SOURCE" ]; then
    echo "Error: OpenSSL license file not found at $OPENSSL_LICENSE_SOURCE"
    exit 1
fi

XCFRAMEWORK_LICENSE_DIR="$XCFRAMEWORK_DIR/Resources/LICENSES"
mkdir -p "$XCFRAMEWORK_LICENSE_DIR"
cp "$OPENSSL_LICENSE_SOURCE" "$XCFRAMEWORK_LICENSE_DIR/OPENSSL-LICENSE.txt"
echo "✓ Embedded OpenSSL license in $XCFRAMEWORK_LICENSE_DIR/OPENSSL-LICENSE.txt"

echo "============================================="
echo "iOS build completed!"
echo "Final xcframework is located in: $XCFRAMEWORK_DIR"
echo "============================================="
