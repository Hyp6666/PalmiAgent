#!/bin/sh

set -euo pipefail

TARGET_DIR="${1:-Vendor/PythonSupport/app_packages}"

if ! command -v python3 >/dev/null 2>&1; then
  echo "error: python3 not found"
  exit 1
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/palmi-app-packages.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

set -- \
  beautifulsoup4==4.14.3 \
  et_xmlfile==2.0.0 \
  mpmath==1.3.0 \
  networkx==3.2.1 \
  openpyxl==3.1.5 \
  packaging==26.1 \
  python-dateutil==2.9.0.post0 \
  pytz==2026.1.post1 \
  six==1.17.0 \
  soupsieve==2.8.3 \
  sympy==1.14.0 \
  tabulate==0.9.0 \
  tomli==2.4.1 \
  tomli-w==1.2.0 \
  typing_extensions==4.15.0 \
  tzdata==2026.1

echo "Vendoring curated pure-Python packages into $TMP_DIR"
python3 -m pip install \
  --disable-pip-version-check \
  --no-compile \
  --only-binary=:all: \
  --target "$TMP_DIR" \
  "$@"

find "$TMP_DIR" -type d -name "__pycache__" -prune -exec rm -rf {} +

rm -rf "$TARGET_DIR"
mkdir -p "$TARGET_DIR"
rsync -a --delete "$TMP_DIR"/ "$TARGET_DIR"/

echo "Installed packages:"
for package in "$@"; do
  echo "  - $package"
done
du -sh "$TARGET_DIR"
