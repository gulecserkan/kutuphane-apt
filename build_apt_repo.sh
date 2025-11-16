#!/usr/bin/env bash
set -euo pipefail

# Basit bir apt depo yapısı üretir.
# Varsayılan kaynak: packaging/dist içindeki .deb dosyaları.
# Çıktı dizini: packaging/apt-repo
#
# Gereksinim: dpkg-scanpackages (dpkg-dev paketi)

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST_DIR="${ROOT}/dist"
REPO_DIR="${APT_REPO_DIR:-${ROOT}/apt-repo}"
POOL_DIR="${REPO_DIR}/pool/main"
PACKAGES_DIR="${REPO_DIR}/dists/stable/main/binary-amd64"

if ! command -v dpkg-scanpackages >/dev/null 2>&1; then
  echo "dpkg-scanpackages yok. 'sudo apt install dpkg-dev' ile kurun." >&2
  exit 1
fi

# Mevcut repo varsa .git'i koru, sadece içerikleri temizle
if [ -d "${REPO_DIR}/.git" ]; then
  rm -rf "${REPO_DIR}/pool" "${REPO_DIR}/dists"
else
  rm -rf "${REPO_DIR}"
fi
mkdir -p "${POOL_DIR}" "${PACKAGES_DIR}"

echo "• .deb dosyaları kopyalanıyor..."
shopt -s nullglob
copied=0
for deb in "${DIST_DIR}"/*.deb; do
  cp -f "${deb}" "${POOL_DIR}/"
  echo "  -> $(basename "${deb}")"
  copied=$((copied+1))
done
shopt -u nullglob

if [ "${copied}" -eq 0 ]; then
  echo "Uyarı: ${DIST_DIR} içinde .deb bulunamadı." >&2
fi

echo "• Packages dosyası üretiliyor..."
(cd "${REPO_DIR}" && dpkg-scanpackages "pool/main" /dev/null > "dists/stable/main/binary-amd64/Packages")
gzip -kf "${PACKAGES_DIR}/Packages"

cat > "${REPO_DIR}/README.txt" <<EOF
Bu dizin basit bir apt deposudur.
Kaynak ekleme örneği:
  deb [trusted=yes] https://.../apt-repo stable main

Üretilen dosyalar:
- pool/main/*.deb
- dists/stable/main/binary-amd64/Packages(.gz)
EOF

echo "Tamamlandı. Depo dizin yapısı:"
echo "  ${REPO_DIR}/pool/main/*.deb"
echo "  ${REPO_DIR}/dists/stable/main/binary-amd64/Packages"
echo "  ${REPO_DIR}/dists/stable/main/binary-amd64/Packages.gz"
