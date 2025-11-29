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
if [ -f "${PREFIX}/setup_backend_service.sh" ]; then
  chmod 755 "${PREFIX}/setup_backend_service.sh" || true
fi

# Paket içine VERSION dosyası bırak
echo "${VERSION}" > "${PREFIX}/VERSION"

cat > "${CONTROL_DIR}/control" <<EOF
Package: ${APP_NAME}
Version: ${VERSION}
Section: web
Priority: optional
Architecture: all
Maintainer: Kutuphane Dev <dev@example.com>
Depends: python3, python3-venv, python3-pip, postgresql, postgresql-client
Description: Okul kütüphanesi sunucu uygulaması
EOF

cat > "${CONTROL_DIR}/postinst" <<'EOF'
#!/bin/sh
set -e
detect_user() {
  if [ -n "${SERVICE_USER_OVERRIDE:-}" ]; then
    echo "${SERVICE_USER_OVERRIDE}"
    return
  fi
  if [ -n "${SUDO_USER:-}" ]; then
    echo "${SUDO_USER}"
    return
  fi
  owner=$(stat -c '%U' "/opt/kutuphane-server" 2>/dev/null || true)
  if [ -n "${owner}" ] && [ "${owner}" != "root" ]; then
    echo "${owner}"
    return
  fi
  fallback=$(getent passwd 1000 2>/dev/null | cut -d: -f1)
  if [ -n "${fallback}" ]; then
    echo "${fallback}"
    return
  fi
  echo "root"
}

APP_ROOT="/opt/kutuphane-server"
ENV_DIR="/etc/kutuphane"
ENV_FILE="${ENV_DIR}/.env"
VENV_DIR="${APP_ROOT}/venv"
REQ_FILE="${APP_ROOT}/requirements.txt"
SUMMARY_FILE="${APP_ROOT}/INSTALL_SUMMARY.txt"
PYTHON="${VENV_DIR}/bin/python"
PIP="${PYTHON} -m pip"
MAINT_DB="postgres"
LOG_FILE="${APP_ROOT}/install.log"
SERVICE_USER=$(detect_user)

ask() {
  prompt="$1"; def="$2"
  if [ -t 0 ]; then
    read -rp "${prompt} [${def}]: " ans
    echo "${ans:-$def}"
  else
    echo "${def}"
  fi
}


ensure_pg_running() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl is-active --quiet postgresql || systemctl start postgresql || return 1
  elif command -v service >/dev/null 2>&1; then
    service postgresql status >/dev/null 2>&1 || service postgresql start || return 1
  else
    return 1
  fi
  return 0
}

mkdir -p "${ENV_DIR}"
: > "${LOG_FILE}"
# .env yoksa varsayılan bir tane oluştur
if [ ! -f "${ENV_FILE}" ]; then
  SECRET_KEY=$(python3 - <<'PY'
import secrets
print(secrets.token_urlsafe(48))
PY
  )
  DB_NAME_DEF="kutuphane"
  DB_USER_DEF="kutuphane"
  DB_PASS_DEF="degistirin"
  DB_HOST_DEF="localhost"
  DB_PORT_DEF="5432"
  SU_USER_DEF="admin"
  SU_EMAIL_DEF="admin@example.com"
  SU_PASS_DEF="degistirin"

  DB_NAME=$(ask "DB adı (küçük harf önerilir)" "$DB_NAME_DEF")
  DB_USER=$(ask "DB kullanıcı (küçük harf önerilir)" "$DB_USER_DEF")
  DB_PASSWORD=$(ask "DB şifre" "$DB_PASS_DEF")
  DB_HOST=$(ask "DB host" "$DB_HOST_DEF")
  DB_PORT=$(ask "DB port" "$DB_PORT_DEF")
  cat > "${ENV_FILE}" <<SAMPLE
SECRET_KEY=${SECRET_KEY}
DEBUG=False
ALLOWED_HOSTS=127.0.0.1,localhost
DB_NAME=${DB_NAME}
DB_USER=${DB_USER}
DB_PASSWORD=${DB_PASSWORD}
DB_HOST=${DB_HOST}
DB_PORT=${DB_PORT}
SAMPLE
  chown "${SERVICE_USER}:${SERVICE_USER}" "${ENV_FILE}" 2>/dev/null || true
  chmod 640 "${ENV_FILE}"
  echo ".env oluşturuldu (${ENV_FILE}). DB bilgilerini ve parolaları güncelleyin."
fi

# .env'yi içe al
set +e
set -a
. "${ENV_FILE}"
set +a
set -e

# venv + pip bağımlılık kurulumu
if [ ! -d "${VENV_DIR}" ]; then
  if ! python3 -m venv "${VENV_DIR}" >>"${LOG_FILE}" 2>&1; then
    echo "Hata: venv oluşturulamadı (${VENV_DIR}). Ayrıntılar: ${LOG_FILE}" >&2
    exit 1
  fi
fi
if [ -x "${VENV_DIR}/bin/pip" ]; then
  if ! ${PIP} install --upgrade pip wheel setuptools >>"${LOG_FILE}" 2>&1; then
    echo "Hata: pip yükseltme başarısız. Ayrıntılar: ${LOG_FILE}" >&2
    exit 1
  fi
  if [ -f "${REQ_FILE}" ]; then
    if ! ${PIP} install --no-cache-dir -r "${REQ_FILE}" >>"${LOG_FILE}" 2>&1; then
      echo "Hata: requirements.txt kurulamadı. Ayrıntılar: ${LOG_FILE}" >&2
      exit 1
    fi
  else
    echo "Uyarı: requirements.txt bulunamadı, pip kurulumu atlandı."
  fi
else
  echo "Uyarı: pip bulunamadı (${VENV_DIR}/bin/pip)."
fi

# PostgreSQL cluster durumu
if command -v pg_lsclusters >/dev/null 2>&1; then
  cluster_ok=1
  running_cnt=$(pg_lsclusters 2>/dev/null | awk 'NR>1 && ($4=="online" || $4=="running"){c++} END{print c+0}')
  if [ "${running_cnt}" -eq 0 ]; then
    first=$(pg_lsclusters 2>/dev/null | awk 'NR==2{print $1" "$2}')
    if [ -n "${first}" ] && command -v pg_ctlcluster >/dev/null 2>&1; then
      ver=$(echo "${first}" | awk '{print $1}')
      name=$(echo "${first}" | awk '{print $2}')
      pg_ctlcluster "${ver}" "${name}" start || cluster_ok=0
    else
      cluster_ok=0
    fi
  fi
  if [ "${cluster_ok}" -eq 0 ]; then
    echo "Hata: Çalışan PostgreSQL cluster bulunamadı. pg_ctlcluster ile başlatın ve yeniden deneyin." >&2
    exit 1
  fi
fi

# PostgreSQL DB/rol oluştur (opsiyonel)
if command -v psql >/dev/null 2>&1; then
  pg_started=1
  ensure_pg_running || pg_started=0
  if [ "${pg_started}" -eq 0 ]; then
    echo "Uyarı: PostgreSQL servisi başlatılamadı, DB/rol oluşturma atlanacak."
  fi
  if [ -t 0 ]; then
    create_db_ans=$(ask "PostgreSQL DB ve kullanıcı oluşturulsun mu? (psql ve çalışan PostgreSQL gerekir)" "h")
  else
    create_db_ans="h"
  fi
  if [ "${pg_started}" -eq 1 ] && { [ "${create_db_ans}" = "E" ] || [ "${create_db_ans}" = "e" ]; }; then
    # Şifre içinde tek tırnakları kaç
    esc_pw=$(printf "%s" "${DB_PASSWORD}" | sed "s/'/''/g")
    PSQL_CMD="psql -d ${MAINT_DB}"
    if command -v sudo >/dev/null 2>&1 && sudo -u postgres true 2>/dev/null; then
      PSQL_CMD="sudo -u postgres psql -d ${MAINT_DB}"
    fi
    # psql erişimi yoksa atla
    if ! ${PSQL_CMD} -v ON_ERROR_STOP=1 -c '\q' >/dev/null 2>&1; then
      echo "Uyarı: postgres yetkisi yok veya psql bağlantısı kurulamadı, DB/rol oluşturma atlandı."
    else
      create_db_ok=1
      # Collation sürümü uyarılarını azaltmak için template veritabanlarını tazele
      ${PSQL_CMD} -c "ALTER DATABASE template1 REFRESH COLLATION VERSION" || true
      ${PSQL_CMD} -c "ALTER DATABASE postgres REFRESH COLLATION VERSION" || true
      role_exists=$(${PSQL_CMD} -v ON_ERROR_STOP=1 -Atc "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'" 2>/dev/null || echo "err")
      if [ "${role_exists}" != "1" ]; then
        ${PSQL_CMD} -v ON_ERROR_STOP=1 -c "CREATE ROLE \"${DB_USER}\" LOGIN PASSWORD '${esc_pw}'" || create_db_ok=0
      else
        ${PSQL_CMD} -v ON_ERROR_STOP=1 -c "ALTER ROLE \"${DB_USER}\" LOGIN PASSWORD '${esc_pw}'" || true
      fi
      db_exists=$(${PSQL_CMD} -v ON_ERROR_STOP=1 -Atc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" 2>/dev/null || echo "err")
      if [ "${db_exists}" != "1" ]; then
        ${PSQL_CMD} -v ON_ERROR_STOP=1 -c "CREATE DATABASE \"${DB_NAME}\" OWNER \"${DB_USER}\"" || create_db_ok=0
      fi
      if [ "${create_db_ok}" -eq 1 ]; then
        ${PSQL_CMD} -v ON_ERROR_STOP=1 -c "GRANT ALL PRIVILEGES ON DATABASE \"${DB_NAME}\" TO \"${DB_USER}\"" || echo "Uyarı: yetki verilemedi."
      else
        echo "Hata: veritabanı oluşturulamadı, yetki verme atlandı. psql ile elle kontrol edin."
        exit 1
      fi
    fi
  elif [ "${create_db_ans}" = "E" ] || [ "${create_db_ans}" = "e" ]; then
    echo "Uyarı: PostgreSQL servisi çalışmıyor, DB/rol oluşturma atlandı."
  fi
else
  echo "Uyarı: psql bulunamadı, DB/rol otomatik oluşturulmadı."
fi

# migrate
if [ -f "${APP_ROOT}/manage.py" ]; then
  PY_CMD="${PYTHON}"
  [ -x "${PYTHON}" ] || PY_CMD="python3"
  (cd "${APP_ROOT}" && ${PY_CMD} manage.py migrate --noinput) || echo "Uyarı: migrate çalıştırılamadı, DB bilgilerini kontrol edin."
  # collectstatic
  echo "collectstatic çalıştırılıyor..."
  (cd "${APP_ROOT}" && ${PY_CMD} manage.py collectstatic --noinput) || echo "Uyarı: collectstatic çalıştırılamadı."
  # superuser oluştur (interaktif)
  if [ -t 0 ]; then
    echo "Süper kullanıcı kontrol ediliyor..."
    set +e
    (cd "${APP_ROOT}" && ${PY_CMD} manage.py shell <<'PY'
from django.contrib.auth import get_user_model
User = get_user_model()
import sys
sys.exit(0 if User.objects.filter(is_superuser=True).exists() else 1)
PY
    )
    status=$?
    set -e
    if [ "${status}" -eq 0 ]; then
      echo "Süper kullanıcı zaten mevcut, atlandı."
    elif [ "${status}" -eq 1 ]; then
      echo "Süper kullanıcı oluşturma başlatılıyor."
      (cd "${APP_ROOT}" && DJANGO_SUPERUSER_PASSWORD= ${PY_CMD} manage.py createsuperuser) || echo "Uyarı: createsuperuser çalıştırılamadı."
    else
      echo "Uyarı: Süper kullanıcı kontrolü başarısız oldu (DB bağlantısı?). Manuel kontrol edin."
    fi
  else
    echo "Not: non-interaktif ortam, createsuperuser atlandı. İhtiyaç varsa manuel çalıştırın."
  fi
fi

# service/cron
if [ -x "${APP_ROOT}/setup_backend_service.sh" ]; then
  echo "Systemd/cron kurulumu deneniyor..."
  SETUP_OUTPUT="$(${APP_ROOT}/setup_backend_service.sh 2>&1)" || {
    echo "setup_backend_service.sh çalıştırılamadı. Çıktı:"
    echo "${SETUP_OUTPUT}"
    echo "Manuel çalıştırmak için: cd ${APP_ROOT} && sudo bash setup_backend_service.sh"
  }
fi
# Servis varsa restart et
if command -v systemctl >/dev/null 2>&1; then
  if systemctl list-unit-files | grep -q "kutuphane-backend.service"; then
    systemctl restart kutuphane-backend || echo "Uyarı: kutuphane-backend restart edilemedi."
  fi
fi
cat > "${SUMMARY_FILE}" <<SUM
Kutuphane Server Kurulum Özeti
-----------------------------
- Kurulum dizini: ${APP_ROOT}
- Sanal ortam: ${VENV_DIR}
- Ortam değişkenleri: ${ENV_FILE} (DB bilgileri, SECRET_KEY vb. burada; gerekirse düzenleyin)
- Gereksinimler: ${REQ_FILE} (pip ile kuruldu)
- Migrasyon: (cd ${APP_ROOT} && ${PY_CMD} manage.py migrate --noinput)
- Süper kullanıcı: (cd ${APP_ROOT} && ${PY_CMD} manage.py createsuperuser)
- Servis kurulumu: ${APP_ROOT}/setup_backend_service.sh (otomatikkurulum denendi, sorun varsa manuel çalıştırın)
- Kaldırma: sudo apt remove kutuphane-server (purge = config dosyalarıyla birlikte)
# Daha fazla bilgi: ${APP_ROOT}/SERVER_SETUP.md
SUM
echo "Kurulum özeti kaydedildi: ${SUMMARY_FILE}"
echo "Özet içeriği:"
cat "${SUMMARY_FILE}"
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
SERVICE_NAME="kutuphane-backend"
CRON_FILE="/etc/cron.d/kutuphane-scheduler"

case "$1" in
  remove|purge)
    systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
    systemctl disable "${SERVICE_NAME}" 2>/dev/null || true
    rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
    systemctl daemon-reload || true
    rm -f "${CRON_FILE}"
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
