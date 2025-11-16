#!/usr/bin/env bash
set -euo pipefail

# Bu scripti apt repo dizininde (örn. ~/kutuphane-apt) çalıştırın.
# Varsayılanları defaults.txt içinde tutar (server/src, desktop/src, version, git remote vb.)

DEFAULTS_FILE="defaults.txt"

get_default() {
  key="$1"
  [ -f "$DEFAULTS_FILE" ] || return 1
  grep -E "^${key}=" "$DEFAULTS_FILE" | tail -1 | cut -d= -f2-
}

set_default() {
  key="$1"; val="$2"
  tmp=$(mktemp)
  grep -Ev "^${key}=" "$DEFAULTS_FILE" 2>/dev/null >> "$tmp" || true
  echo "${key}=${val}" >> "$tmp"
  mv "$tmp" "$DEFAULTS_FILE"
}

decode_path() {
  # defaults.txt içinde \ boşluk yazıldıysa gerçek boşluğa çevir
  echo "${1//\\ / }"
}

ask() {
  prompt="$1"; def="$2"
  read -rp "${prompt} [${def}]: " ans
  echo "${ans:-$def}"
}

run_build_server() {
  src_def_raw=$(get_default SERVER_SRC || echo "/path/to/server")
  src_def=$(decode_path "$src_def_raw")
  ver_def=$(get_default SERVER_VER || echo "1.0.0")
  src=$(ask "Server kaynak dizini" "$src_def")
  src=$(decode_path "$src")
  ver=$(ask "Server version" "$ver_def")
  set_default SERVER_SRC "$src"
  set_default SERVER_VER "$ver"
  OUTPUT_BASE="${SCRIPT_DIR}" VERSION="$ver" "$BUILD_SERVER" "$src"
}

run_build_desktop() {
  src_def_raw=$(get_default DESKTOP_SRC || echo "/path/to/desktop")
  src_def=$(decode_path "$src_def_raw")
  ver_def=$(get_default DESKTOP_VER || echo "1.0.0")
  src=$(ask "Desktop kaynak dizini" "$src_def")
  src=$(decode_path "$src")
  ver=$(ask "Desktop version" "$ver_def")
  set_default DESKTOP_SRC "$src"
  set_default DESKTOP_VER "$ver"
  OUTPUT_BASE="${SCRIPT_DIR}" VERSION="$ver" "$BUILD_DESKTOP" "$src"
}

run_repo() {
  OUTPUT_BASE="${SCRIPT_DIR}" APT_REPO_DIR="${SCRIPT_DIR}/apt-repo" "$BUILD_REPO"
}

run_push() {
  remote_def=$(get_default GIT_REMOTE || echo "")
  user_def=$(get_default GIT_USER || echo "")
  token_def=$(get_default GIT_PAT || echo "")
  msg_def=$(get_default GIT_MSG || echo "Update packages")

  remote=$(ask "Remote URL" "$remote_def")
  user=$(ask "Git kullanıcı" "$user_def")
  token=$(ask "PAT (boş bırakırsan mevcut auth kullanılır)" "$token_def")
  msg=$(ask "Commit mesajı" "$msg_def")

  set_default GIT_REMOTE "$remote"
  set_default GIT_USER "$user"
  set_default GIT_PAT "$token"
  set_default GIT_MSG "$msg"

  [ -n "$remote" ] && git remote set-url origin "$remote" || true
  git add .
  git commit -m "$msg" || echo "Commit edecek değişiklik yok."
  if [ -n "$token" ]; then
    git push "https://${user}:${token}@${remote#https://}" HEAD:main
  else
    git push
  fi
}

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BUILD_ROOT="${SCRIPT_DIR}"
BUILD_SERVER="${BUILD_ROOT}/build_server_deb.sh"
BUILD_DESKTOP="${BUILD_ROOT}/build_desktop_deb.sh"
BUILD_REPO="${BUILD_ROOT}/build_apt_repo.sh"

if [ ! -x "$BUILD_SERVER" ] || [ ! -x "$BUILD_DESKTOP" ] || [ ! -x "$BUILD_REPO" ]; then
  echo "build scriptleri bulunamadı ya da çalıştırılamıyor. packaging klasörünü kontrol edin." >&2
  exit 1
fi

while true; do
  echo "Ne yapacaksınız?"
  echo "1) build-server"
  echo "2) build-desktop"
  echo "3) her ikisi de"
  echo "4) commit ve push"
  echo "5) çıkış"
  read -rp "Seçim: " opt
  case "$opt" in
    1) run_build_server; run_repo ;;
    2) run_build_desktop; run_repo ;;
    3) run_build_server; run_build_desktop; run_repo ;;
    4) run_push ;;
    5) exit 0 ;;
    *) echo "Geçersiz seçim" ;;
  esac
done
