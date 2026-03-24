# OpenSSL Prebuilt for Android & iOS

This repository contains build scripts and GitHub Actions workflows to cross-compile OpenSSL for Android and iOS. It serves as a centralized source for prebuilt OpenSSL binaries used in mobile applications and other libraries (like `libcurl`).

## Quick Usage

### Android (via Maven)

Add the repository to your `build.gradle` and define the dependency:

```gradle
repositories {
    maven { url "https://xdcobra.github.io/maven" }
}

dependencies {
    // Add the native OpenSSL libraries (shared and static)
    implementation "com.xdcobra.openssl:openssl:3.6.1-1@aar"
}
```

### iOS (via XCFramework)

1. Download the latest `openssl.xcframework` from the [GitHub Releases](https://github.com/XDcobra/openssl-ios-android-prebuilt-and-buildscripts/releases).
2. Add the `openssl.xcframework` to your Xcode project under **Frameworks, Libraries, and Embedded Content**.
3. Set the embed status to **Embed & Sign** (if linking dynamically) or **Do Not Embed** (if linking statically, which is recommended for `libopenssl.a` wrapped in XCFramework).

---

## Features

- **Android Support**: Compiles for `armeabi-v7a`, `arm64-v8a`, `x86`, and `x86_64`.
  - Generates both Shared (`.so`) and Static (`.a`) libraries.
  - Targets Android API Level 24.
- **iOS Support**: Compiles for physical devices (`arm64`) and simulators (`arm64`, `x86_64`).
  - Generates a unified **`openssl.xcframework`** (Umbrella Framework).
  - Combines `libssl` and `libcrypto` into a single static library for easier integration.
- **CI/CD**: Fully automated release pipeline via GitHub Actions.
  - Publishes AARs to a private Maven repository.
  - Creates GitHub Releases with ZIP archives of the build artifacts.

## Repository Structure

- `openssl/`: Git submodule pointing to the official OpenSSL source.
- `build-android.sh`: Bash script to build for all Android ABIs.
- `build-ios.sh`: Bash script to build for iOS and generate the XCFramework.
- `.github/workflows/`: GitHub Action definitions for CI/CD and automated releases.

## Local Build Instructions

### Prerequisites

- **macOS**: Required for building iOS XCFrameworks.
- **Xcode**: Installed and configured (`xcode-select`).
- **Android NDK**: Path should be set in `$ANDROID_NDK_ROOT` or `$ANDROID_NDK_HOME`.

### Building for Android

```bash
chmod +x build-android.sh
./build-android.sh
```
The output will be located in `build/android/`.

### Building for iOS

```bash
chmod +x build-ios.sh
./build-ios.sh
```
The output will be located in `build/ios/openssl.xcframework`.

## CI/CD and Releases

### Tagging Convention

Versions follow the pattern `v<openssl_version>-<build_number>`.
Example: `v3.6.1-1`

Pushing a tag will trigger the `Release Main` workflow, which builds all platforms and publishes the artifacts.

### Maven Release

Android binaries are packaged as an AAR and published to the [XDcobra/maven](https://github.com/XDcobra/maven) repository.

**Gradle Usage:**
```gradle
repositories {
    maven { url "https://xdcobra.github.io/maven" }
}

dependencies {
    implementation "com.xdcobra.openssl:openssl:3.6.1-1@aar"
}
```

## License

This repository is licensed under the MIT License. OpenSSL itself is licensed under its own [OpenSSL License](https://www.openssl.org/source/license.html).