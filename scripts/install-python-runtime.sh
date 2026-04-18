#!/bin/sh

set -euo pipefail

PYTHON_XCFRAMEWORK_PATH="$PROJECT_DIR/Vendor/PythonSupport/Python.xcframework"

if [ ! -d "$PYTHON_XCFRAMEWORK_PATH" ]; then
  echo "error: Python.xcframework not found at $PYTHON_XCFRAMEWORK_PATH"
  exit 1
fi

case "${EFFECTIVE_PLATFORM_NAME:-}" in
  -iphonesimulator)
    SLICE_FOLDER="ios-arm64_x86_64-simulator"
    if printf '%s' "${ARCHS:-}" | grep -q ' '; then
      if [ -n "${NATIVE_ARCH_ACTUAL:-}" ] && [ "${NATIVE_ARCH_ACTUAL}" != "undefined_arch" ]; then
        export ARCHS="${NATIVE_ARCH_ACTUAL}"
      elif [ "$(uname -m)" = "arm64" ]; then
        export ARCHS="arm64"
      else
        export ARCHS="x86_64"
      fi
    fi
    ;;
  -iphoneos)
    SLICE_FOLDER="ios-arm64"
    ;;
  *)
    echo "error: unsupported platform $EFFECTIVE_PLATFORM_NAME for embedded Python runtime"
    exit 1
    ;;
esac

FRAMEWORKS_DIR="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH"
mkdir -p "$FRAMEWORKS_DIR"

echo "Embedding Python.framework from $SLICE_FOLDER"
rsync -au --delete \
  "$PYTHON_XCFRAMEWORK_PATH/$SLICE_FOLDER/Python.framework" \
  "$FRAMEWORKS_DIR/"

if [ "${CODE_SIGNING_ALLOWED:-NO}" = "YES" ] && [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
  echo "Codesigning embedded Python.framework"
  /usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" ${OTHER_CODE_SIGN_FLAGS:-} \
    -o runtime --timestamp=none --preserve-metadata=identifier,entitlements,flags \
    --generate-entitlement-der "$FRAMEWORKS_DIR/Python.framework"
fi

echo "Installing Python standard library and binary modules"
if [ "${CODE_SIGNING_ALLOWED:-NO}" != "YES" ]; then
  export EXPANDED_CODE_SIGN_IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:--}"
  export EXPANDED_CODE_SIGN_IDENTITY_NAME="${EXPANDED_CODE_SIGN_IDENTITY_NAME:-Ad Hoc}"
fi
. "$PYTHON_XCFRAMEWORK_PATH/build/utils.sh"
install_python "Vendor/PythonSupport/Python.xcframework"
