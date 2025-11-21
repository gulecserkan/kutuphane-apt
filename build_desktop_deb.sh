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
Depends: python3, python3-venv, python3-pip, python3-pyqt5
Description: Okul kütüphanesi masaüstü istemcisi
EOF

cat > "${CONTROL_DIR}/postinst" <<'EOF'
#!/bin/sh
set -e
/opt/kutuphane-desktop/install_desktop_entry.sh || true

APP_ROOT="/opt/kutuphane-desktop"
VENV_DIR="${APP_ROOT}/venv"
SUMMARY_FILE="${APP_ROOT}/INSTALL_SUMMARY.txt"
REQ_FALLBACK="${APP_ROOT}/requirements.txt"

if [ ! -d "${VENV_DIR}" ]; then
  python3 -m venv "${VENV_DIR}" || echo "Uyarı: venv oluşturulamadı (${VENV_DIR})."
fi
if [ -x "${VENV_DIR}/bin/pip" ]; then
  "${VENV_DIR}/bin/pip" install --upgrade pip wheel setuptools || echo "Uyarı: pip yükseltilemedi."
  if [ -f "${REQ_FALLBACK}" ]; then
    "${VENV_DIR}/bin/pip" install --no-cache-dir -r "${REQ_FALLBACK}" || echo "Uyarı: requirements.txt kurulamadı."
  else
    echo "Uyarı: requirements.txt bulunamadı, pip kurulumu atlandı."
  fi
else
  echo "Uyarı: pip bulunamadı (${VENV_DIR}/bin/pip)."
fi

PY_CMD="${VENV_DIR}/bin/python"
[ -x "${PY_CMD}" ] || PY_CMD="python3"

cat > "${SUMMARY_FILE}" <<SUM
Kutuphane Desktop Kurulum Özeti
-------------------------------
- Kurulum dizini: ${APP_ROOT}
- Sanal ortam: ${VENV_DIR}
- Gereksinimler: ${REQ_FALLBACK} (pip ile kurulduysa)
- Çalıştırma: uygulama menüsündeki kısayol veya (cd ${APP_ROOT} && ${PY_CMD} main.py)
- Kaldırma: sudo apt remove kutuphane-desktop (purge = config dosyalarıyla birlikte)
SUM
echo "Kurulum özeti kaydedildi: ${SUMMARY_FILE}"
echo "Özet içeriği:"
cat "${SUMMARY_FILE}"

exit 0
EOF
chmod 755 "${CONTROL_DIR}/postinst"

cat > "${CONTROL_DIR}/postrm" <<'EOF'
#!/bin/sh
set -e
APP_NAME="kutuphane"
target_user="${SUDO_USER:-$(logname 2>/dev/null || echo "$USER")}"
target_home="$(eval echo "~${target_user}")"
DESKTOP_FILE="${target_home}/.local/share/applications/${APP_NAME}.desktop"
EXEC_WRAPPER="${target_home}/.local/bin/${APP_NAME}"
ICON_FILE="${target_home}/.local/share/icons/hicolor/256x256/apps/${APP_NAME}.png"

rm -f "${DESKTOP_FILE}" "${EXEC_WRAPPER}" "${ICON_FILE}"
exit 0
EOF
chmod 755 "${CONTROL_DIR}/postrm"

if [ -f "${ICON_SRC}" ]; then
  mkdir -p "${BUILD_DIR}/usr/share/icons/hicolor/256x256/apps"
  install -m 644 "${ICON_SRC}" "${BUILD_DIR}/usr/share/icons/hicolor/256x256/apps/${APP_NAME}.png"
fi

echo "Paketleniyor..."
dpkg-deb --build "${BUILD_DIR}" "${DIST_DIR}/${APP_NAME}_${VERSION}.deb"
echo "Oluşturuldu: ${DIST_DIR}/${APP_NAME}_${VERSION}.deb"
