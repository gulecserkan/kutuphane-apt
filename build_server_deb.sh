#!/usr/bin/env bash
set -euo pipefail

if [ $# -lt 1 ]; then
  echo "Kullanım: $0 /path/to/server_repo [version]"
  exit 1
fi

SERVER_ROOT="$(cd "$1" && pwd)"
APP_NAME="kutuphane-server"
VERSION="${2:-${VERSION:-0.1.0}}"
OUTPUT_BASE="${OUTPUT_BASE:-$(pwd)}"
BUILD_DIR="${OUTPUT_BASE}/.build/${APP_NAME}_${VERSION}"
DIST_DIR="${OUTPUT_BASE}/dist"
PREFIX="${BUILD_DIR}/opt/kutuphane-server"
CONTROL_DIR="${BUILD_DIR}/DEBIAN"

rm -rf "${BUILD_DIR}"
mkdir -p "${PREFIX}" "${CONTROL_DIR}" "${DIST_DIR}"

echo "Staging sunucu kodu: ${SERVER_ROOT}"
rsync -a --delete \
  --exclude ".git" \
  --exclude "venv" \
  --exclude "__pycache__" \
  --exclude "*.pyc" \
  --exclude "kutuphane_desktop" \
  "${SERVER_ROOT}/" "${PREFIX}/"

# Paket içine VERSION dosyası bırak
echo "${VERSION}" > "${PREFIX}/VERSION"

cat > "${CONTROL_DIR}/control" <<EOF
Package: ${APP_NAME}
Version: ${VERSION}
Section: web
Priority: optional
Architecture: all
Maintainer: Kutuphane Dev <dev@example.com>
Depends: python3, python3-django, python3-djangorestframework, python3-djangorestframework-simplejwt, python3-psycopg2, python3-requests
Description: Okul kütüphanesi sunucu uygulaması
EOF

cat > "${CONTROL_DIR}/postinst" <<'EOF'
#!/bin/sh
set -e
APP_ROOT="/opt/kutuphane-server"
ENV_DIR="/etc/kutuphane"
ENV_FILE="${ENV_DIR}/.env"

mkdir -p "${ENV_DIR}"
# .env yoksa varsayılan bir tane oluştur
if [ ! -f "${ENV_FILE}" ]; then
  SECRET_KEY=$(python3 - <<'PY'
import secrets
print(secrets.token_urlsafe(48))
PY
  )
  cat > "${ENV_FILE}" <<SAMPLE
SECRET_KEY=${SECRET_KEY}
DEBUG=False
ALLOWED_HOSTS=127.0.0.1,localhost
DB_NAME=kutuphane
DB_USER=kutuphane
DB_PASSWORD=degistirin
DB_HOST=localhost
DB_PORT=5432
DJANGO_SUPERUSER_USERNAME=admin
DJANGO_SUPERUSER_EMAIL=admin@example.com
DJANGO_SUPERUSER_PASSWORD=degistirin
SAMPLE
  chmod 640 "${ENV_FILE}"
  echo ".env oluşturuldu (${ENV_FILE}). DB bilgilerini ve parolaları güncelleyin."
fi

# .env'yi içe al
set +e
set -a
. "${ENV_FILE}"
set +a
set -e

# migrate
if [ -f "${APP_ROOT}/manage.py" ]; then
  (cd "${APP_ROOT}" && python3 manage.py migrate --noinput) || echo "Uyarı: migrate çalıştırılamadı, DB bilgilerini kontrol edin."
  # superuser oluştur (yoksa)
  (cd "${APP_ROOT}" && python3 manage.py shell <<'PY' || true
import os
from django.contrib.auth import get_user_model
User = get_user_model()
username = os.environ.get("DJANGO_SUPERUSER_USERNAME", "admin")
email = os.environ.get("DJANGO_SUPERUSER_EMAIL", "admin@example.com")
password = os.environ.get("DJANGO_SUPERUSER_PASSWORD", "admin")
if not User.objects.filter(username=username).exists():
    User.objects.create_superuser(username=username, email=email, password=password)
    print("Superuser oluşturuldu:", username)
else:
    print("Superuser zaten mevcut:", username)
PY
  )
fi

# service/cron
if [ -x "${APP_ROOT}/setup_backend_service.sh" ]; then
  echo "Systemd/cron kurulumu deneniyor..."
  "${APP_ROOT}/setup_backend_service.sh" || echo "setup_backend_service.sh çalıştırılamadı, manuel kurulum yapın."
fi
echo "Kurulum tamamlandı."
echo "• Yapılandırma için .env dosyasını düzenleyin: ${ENV_FILE}"
echo "• Detaylı yönergeler: ${APP_ROOT}/SERVER_SETUP.md (ve django_deployment_checklist.md)"
exit 0
EOF
chmod 755 "${CONTROL_DIR}/postinst"

cat > "${CONTROL_DIR}/postrm" <<'EOF'
#!/bin/sh
set -e
APP_ROOT="/opt/kutuphane-server"
ENV_DIR="/etc/kutuphane"

case "$1" in
  remove|purge)
    rm -rf "${APP_ROOT}"
    if [ "$1" = "purge" ]; then
      rm -rf "${ENV_DIR}"
    fi
    ;;
esac
exit 0
EOF
chmod 755 "${CONTROL_DIR}/postrm"

echo "Paketleniyor..."
dpkg-deb --build "${BUILD_DIR}" "${DIST_DIR}/${APP_NAME}_${VERSION}.deb"
echo "Oluşturuldu: ${DIST_DIR}/${APP_NAME}_${VERSION}.deb"
