#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="${1:-${ROOT}}"
APP_NAME="kutuphane-desktop"
VERSION="${VERSION:-0.1.0}"
OUTPUT_BASE="${OUTPUT_BASE:-$(pwd)}"
BUILD_DIR="${OUTPUT_BASE}/.build/${APP_NAME}_${VERSION}"
DIST_DIR="${OUTPUT_BASE}/dist"
PREFIX="${BUILD_DIR}/opt/kutuphane-desktop"
CONTROL_DIR="${BUILD_DIR}/DEBIAN"
ICON_SRC="${SRC_DIR}/resources/icons/library.png"

rm -rf "${BUILD_DIR}"
mkdir -p "${PREFIX}" "${CONTROL_DIR}" "${DIST_DIR}"

echo "Staging masaüstü uygulaması..."
rsync -a --delete \
  --exclude ".git" \
  --exclude "packaging" \
  --exclude "venv" \
  --exclude "__pycache__" \
  --exclude "*.pyc" \
  "${SRC_DIR}/" "${PREFIX}/"

# Paket içine VERSION dosyası bırak
echo "${VERSION}" > "${PREFIX}/VERSION"

cat > "${CONTROL_DIR}/control" <<EOF
Package: ${APP_NAME}
Version: ${VERSION}
Section: utils
Priority: optional
Architecture: all
Maintainer: Kutuphane Dev <dev@example.com>
Depends: python3, python3-pyqt5, python3-requests
Description: Okul kütüphanesi masaüstü istemcisi
EOF

cat > "${CONTROL_DIR}/postinst" <<'EOF'
#!/bin/sh
set -e
/opt/kutuphane-desktop/install_desktop_entry.sh || true
exit 0
EOF
chmod 755 "${CONTROL_DIR}/postinst"

if [ -f "${ICON_SRC}" ]; then
  mkdir -p "${BUILD_DIR}/usr/share/icons/hicolor/256x256/apps"
  install -m 644 "${ICON_SRC}" "${BUILD_DIR}/usr/share/icons/hicolor/256x256/apps/${APP_NAME}.png"
fi

echo "Paketleniyor..."
dpkg-deb --build "${BUILD_DIR}" "${DIST_DIR}/${APP_NAME}_${VERSION}.deb"
echo "Oluşturuldu: ${DIST_DIR}/${APP_NAME}_${VERSION}.deb"
