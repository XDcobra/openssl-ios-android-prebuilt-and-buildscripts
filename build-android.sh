#!/bin/bash
set -e

# Verify Android NDK
if [ -z "$ANDROID_NDK_ROOT" ]; then
    if [ -n "$ANDROID_NDK_HOME" ]; then
        export ANDROID_NDK_ROOT="$ANDROID_NDK_HOME"
    else
        echo "Error: ANDROID_NDK_ROOT or ANDROID_NDK_HOME must be set."
        exit 1
    fi
fi

# Determine Host OS for NDK Toolchain path
HOST_OS=$(uname -s | tr '[:upper:]' '[:lower:]')
if [ "$HOST_OS" = "darwin" ]; then
    TOOLCHAIN_HOST="darwin-x86_64"
elif [ "$HOST_OS" = "linux" ]; then
    TOOLCHAIN_HOST="linux-x86_64"
else
    echo "Error: Unsupported host OS: $HOST_OS"
    exit 1
fi

# Add NDK toolchain to PATH (Required by OpenSSL compilation scripts)
export PATH="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/$TOOLCHAIN_HOST/bin:$PATH"

API_LEVEL=24
OUT_DIR="$(pwd)/build/android"
mkdir -p "$OUT_DIR/include"

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
OPENSSL_LICENSE_OUT_DIR="$OUT_DIR/licenses/openssl"

echo "Building for Android (API Level $API_LEVEL)..."

cd openssl

ABIS=("armeabi-v7a" "arm64-v8a" "x86" "x86_64")
TARGETS=("android-arm" "android-arm64" "android-x86" "android-x86_64")

for i in "${!ABIS[@]}"; do
    ABI="${ABIS[$i]}"
    TARGET="${TARGETS[$i]}"
    
    echo "============================================="
    echo "Building for $ABI ($TARGET)..."
    echo "============================================="
    
    # Clean up previous build if Makefile exists
    if [ -f Makefile ]; then
        make clean || true
    fi
    
    # Configure OpenSSL for target architecture
    ./Configure $TARGET -D__ANDROID_API__=$API_LEVEL shared
    
    # Compile using all available CPU cores
    make -j$(sysctl -n hw.ncpu 2>/dev/null || nproc)
    
    # Create directory for current ABI
    ABI_LIB="$OUT_DIR/jniLibs/$ABI"
    mkdir -p "$ABI_LIB"
    
    # Copy headers (can be overwritten safely)
    cp -r include/openssl "$OUT_DIR/include/"
    
    # Output shared libraries (resolve symlinks via cp -L)
    cp -L libcrypto.so "$ABI_LIB/libcrypto.so"
    cp -L libssl.so "$ABI_LIB/libssl.so"
    
    # Output static libraries
    cp libcrypto.a "$ABI_LIB/libcrypto.a"
    cp libssl.a "$ABI_LIB/libssl.a"
done

if [ -z "$OPENSSL_LICENSE_SOURCE" ] || [ ! -f "$OPENSSL_LICENSE_SOURCE" ]; then
    echo "Error: OpenSSL license file not found at $OPENSSL_LICENSE_SOURCE"
    exit 1
fi

mkdir -p "$OPENSSL_LICENSE_OUT_DIR"
cp "$OPENSSL_LICENSE_SOURCE" "$OPENSSL_LICENSE_OUT_DIR/OPENSSL-LICENSE.txt"
echo "✓ Copied OpenSSL license to $OPENSSL_LICENSE_OUT_DIR/OPENSSL-LICENSE.txt"

echo "============================================="
echo "Android build completed!"
echo "All files are located in: $OUT_DIR"
echo "============================================="
