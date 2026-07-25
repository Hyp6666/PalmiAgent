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

echo "Cleaning stale Python extension frameworks"
find "$FRAMEWORKS_DIR" -maxdepth 1 -type d -name "*.framework" ! -name "Python.framework" | while read framework; do
  if find "$framework" -maxdepth 1 -name "*.origin" -print -quit | grep -q .; then
    rm -rf "$framework"
  fi
done

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

for module in _ssl _hashlib; do
  privacy_manifest="$FRAMEWORKS_DIR/$module.framework/PrivacyInfo.xcprivacy"

  if [ ! -f "$privacy_manifest" ]; then
    echo "error: Missing PrivacyInfo.xcprivacy in $module.framework"
    exit 1
  fi

  /usr/bin/plutil -lint "$privacy_manifest"
  echo "Verified privacy manifest: $privacy_manifest"
done

PYTHON_VER=$(find "$CODESIGNING_FOLDER_PATH/python/lib" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | head -n 1)
if [ -z "$PYTHON_VER" ]; then
  echo "error: failed to locate bundled Python version directory"
  exit 1
fi

PYTHON_STDLIB_DIR="$CODESIGNING_FOLDER_PATH/python/lib/$PYTHON_VER"
PYTHON_SITE_PACKAGES_DIR="$PYTHON_STDLIB_DIR/site-packages"
APP_PACKAGES_SOURCE="$PROJECT_DIR/Vendor/PythonSupport/app_packages"

echo "Pruning bulky stdlib directories"
for name in test idlelib tkinter turtledemo ensurepip; do
  if [ -e "$PYTHON_STDLIB_DIR/$name" ]; then
    rm -rf "$PYTHON_STDLIB_DIR/$name"
  fi
done
find "$PYTHON_STDLIB_DIR" -type d -name "__pycache__" -prune -exec rm -rf {} +

if [ -d "$APP_PACKAGES_SOURCE" ]; then
  echo "Installing curated pure-Python packages"
  mkdir -p "$PYTHON_SITE_PACKAGES_DIR"
  rsync -au --delete --exclude "__pycache__/" "$APP_PACKAGES_SOURCE/" "$PYTHON_SITE_PACKAGES_DIR/"
  process_dylibs "Vendor/PythonSupport/Python.xcframework" "python/lib/$PYTHON_VER/site-packages"
fi
