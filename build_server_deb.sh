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
Depends: python3, python3-venv, python3-pip, postgresql, postgresql-client
Description: Okul kütüphanesi sunucu uygulaması
EOF

cat > "${CONTROL_DIR}/postinst" <<'EOF'
#!/bin/sh
set -e
APP_ROOT="/opt/kutuphane-server"
ENV_DIR="/etc/kutuphane"
ENV_FILE="${ENV_DIR}/.env"
VENV_DIR="${APP_ROOT}/venv"
REQ_FILE="${APP_ROOT}/requirements.txt"
SUMMARY_FILE="${APP_ROOT}/INSTALL_SUMMARY.txt"
DEBUG_LOG="${APP_ROOT}/install_debug.log"
PYTHON="${VENV_DIR}/bin/python"
PIP="${PYTHON} -m pip"
MAINT_DB="postgres"

ask() {
  prompt="$1"; def="$2"
  if [ -t 0 ]; then
    read -rp "${prompt} [${def}]: " ans
    echo "${ans:-$def}"
  else
    echo "${def}"
  fi
}

debug_step() {
  step="$1"
  mkdir -p "$(dirname "${DEBUG_LOG}")" 2>/dev/null || true
  echo "DEBUG_STEP: ${step}" | tee -a "${DEBUG_LOG}" || true
}

debug_db() {
  msg="$1"
  mkdir -p "$(dirname "${DEBUG_LOG}")" 2>/dev/null || true
  echo "DB_DEBUG: ${msg}" | tee -a "${DEBUG_LOG}" || true
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
debug_step "start"
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
  chmod 640 "${ENV_FILE}"
  echo ".env oluşturuldu (${ENV_FILE}). DB bilgilerini ve parolaları güncelleyin."
fi
debug_step "env_ready"

# .env'yi içe al
set +e
set -a
. "${ENV_FILE}"
set +a
set -e

# venv + pip bağımlılık kurulumu
if [ ! -d "${VENV_DIR}" ]; then
  python3 -m venv "${VENV_DIR}" || echo "Uyarı: venv oluşturulamadı (${VENV_DIR}). python3-venv var mı kontrol edin."
fi
if [ -x "${VENV_DIR}/bin/pip" ]; then
  ${PIP} install --upgrade pip wheel setuptools || echo "Uyarı: pip yükseltilemedi."
  if [ -f "${REQ_FILE}" ]; then
    ${PIP} install --no-cache-dir -r "${REQ_FILE}" || echo "Uyarı: requirements.txt kurulamadı."
  else
    echo "Uyarı: requirements.txt bulunamadı, pip kurulumu atlandı."
  fi
else
  echo "Uyarı: pip bulunamadı (${VENV_DIR}/bin/pip)."
fi
debug_step "pip_done"

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
  debug_db "İstenen DB bilgileri: name=${DB_NAME}, user=${DB_USER}, host=${DB_HOST}, port=${DB_PORT}"
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
      debug_db "Komut: ${PSQL_CMD} -c \"DROP DATABASE IF EXISTS \\\"${DB_NAME}\\\"\""
      ${PSQL_CMD} -v ON_ERROR_STOP=1 -c "DROP DATABASE IF EXISTS \"${DB_NAME}\"" || true
      debug_db "Komut: ${PSQL_CMD} -c \"DROP ROLE IF EXISTS \\\"${DB_USER}\\\"\""
      ${PSQL_CMD} -v ON_ERROR_STOP=1 -c "DROP ROLE IF EXISTS \"${DB_USER}\"" || true
      debug_db "Komut: ${PSQL_CMD} -c \"CREATE ROLE \\\"${DB_USER}\\\" LOGIN PASSWORD '***'\""
      ${PSQL_CMD} -v ON_ERROR_STOP=1 -c "CREATE ROLE \"${DB_USER}\" LOGIN PASSWORD '${esc_pw}'" || create_db_ok=0
      if [ "${create_db_ok}" -eq 1 ]; then
        debug_db "Komut: ${PSQL_CMD} -c \"CREATE DATABASE \\\"${DB_NAME}\\\" OWNER \\\"${DB_USER}\\\"\""
        ${PSQL_CMD} -v ON_ERROR_STOP=1 -c "CREATE DATABASE \"${DB_NAME}\" OWNER \"${DB_USER}\"" || create_db_ok=0
      fi
      if [ "${create_db_ok}" -eq 1 ]; then
        debug_db "Komut: ${PSQL_CMD} -c \"GRANT ALL PRIVILEGES ON DATABASE \\\"${DB_NAME}\\\" TO \\\"${DB_USER}\\\"\""
        ${PSQL_CMD} -v ON_ERROR_STOP=1 -c "GRANT ALL PRIVILEGES ON DATABASE \"${DB_NAME}\" TO \"${DB_USER}\"" || echo "Uyarı: yetki verilemedi."
      else
        echo "Uyarı: veritabanı oluşturulamadı, yetki verme atlandı. psql ile elle kontrol edin."
      fi
    fi
  elif [ "${create_db_ans}" = "E" ] || [ "${create_db_ans}" = "e" ]; then
    echo "Uyarı: PostgreSQL servisi çalışmıyor, DB/rol oluşturma atlandı."
  fi
else
  echo "Uyarı: psql bulunamadı, DB/rol otomatik oluşturulmadı."
fi
debug_step "db_done"

# migrate
if [ -f "${APP_ROOT}/manage.py" ]; then
  PY_CMD="${PYTHON}"
  [ -x "${PYTHON}" ] || PY_CMD="python3"
  (cd "${APP_ROOT}" && ${PY_CMD} manage.py migrate --noinput) || echo "Uyarı: migrate çalıştırılamadı, DB bilgilerini kontrol edin."
  # collectstatic
  if [ -n "${COLLECT_STATIC:-}" ] || [ -d "${APP_ROOT}/static" ] || [ -d "${APP_ROOT}/staticfiles" ]; then
    echo "collectstatic çalıştırılıyor..."
    (cd "${APP_ROOT}" && ${PY_CMD} manage.py collectstatic --noinput) || echo "Uyarı: collectstatic çalıştırılamadı."
  fi
  # superuser oluştur (interaktif)
  if [ -t 0 ]; then
    echo "Süper kullanıcı oluşturma başlatılıyor (mevcutsa atlanır)."
    (cd "${APP_ROOT}" && DJANGO_SUPERUSER_PASSWORD= ${PY_CMD} manage.py createsuperuser) || echo "Uyarı: createsuperuser çalıştırılamadı."
  else
    echo "Not: non-interaktif ortam, createsuperuser atlandı. İhtiyaç varsa manuel çalıştırın."
  fi
fi
debug_step "django_done"

# service/cron
if [ -x "${APP_ROOT}/setup_backend_service.sh" ]; then
  echo "Systemd/cron kurulumu deneniyor..."
  "${APP_ROOT}/setup_backend_service.sh" || echo "setup_backend_service.sh çalıştırılamadı, manuel kurulum yapın."
fi
debug_step "service_done"
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
