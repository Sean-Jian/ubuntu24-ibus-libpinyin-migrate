#!/usr/bin/env bash
# Ubuntu 24.04 GNOME IBus/LibPinyin migration helper
# SPDX-License-Identifier: MIT
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

PROGRAM=${0##*/}
STATE_HOME=${XDG_STATE_HOME:-"$HOME/.local/state"}
BACKUP_ROOT="$STATE_HOME/input-method-migrate/backups"

log()  { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
die()  { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "Missing command / 缺少命令: $1"; }

usage() {
  cat <<EOF
Usage / 用法:
  $PROGRAM export [bundle.tar.gz]
  $PROGRAM import <bundle.tar.gz>
  $PROGRAM inspect <bundle.tar.gz>
  $PROGRAM check
  $PROGRAM list-backups
  $PROGRAM rollback <backup-directory>

Run as the logged-in desktop user, not with sudo.
请以当前桌面用户运行，不要 sudo 运行整个脚本。
EOF
}

check_user() {
  [[ ${EUID:-$(id -u)} -ne 0 ]] || die "Do not run the whole script with sudo."
  [[ -n ${HOME:-} && $HOME == /* && $HOME != / ]] || die "Unsafe HOME."
}

check_platform() {
  local id version
  # shellcheck disable=SC1091
  . /etc/os-release
  id=${ID:-unknown}; version=${VERSION_ID:-unknown}
  [[ $id == ubuntu && $version == 24.04 ]] ||
    warn "Designed for Ubuntu 24.04; detected $id $version."
}

managed_paths() {
  printf '%s\n' .cache/ibus/libpinyin .local/share/libpinyin .config/libpinyin .xinputrc
}

stop_input_methods() {
  if command -v fcitx5-remote >/dev/null 2>&1; then
    fcitx5-remote -e >/dev/null 2>&1 || true
  fi
  pkill -TERM -u "$(id -u)" -x fcitx5 >/dev/null 2>&1 || true
  if command -v ibus >/dev/null 2>&1; then
    ibus exit >/dev/null 2>&1 || true
  fi
  sleep 1
}

start_ibus() {
  if systemctl --user cat org.freedesktop.IBus.session.GNOME.service >/dev/null 2>&1; then
    systemctl --user reset-failed org.freedesktop.IBus.session.GNOME.service >/dev/null 2>&1 || true
    systemctl --user start org.freedesktop.IBus.session.GNOME.service >/dev/null 2>&1 || true
  else
    nohup ibus-daemon --daemonize --xim >/dev/null 2>&1 || true
  fi
}

capture() {
  local dest=$1 rel
  local -a present=()
  mkdir -p "$dest/dconf" "$dest/gsettings" "$dest/conflicts"
  dconf dump /org/freedesktop/ibus/ >"$dest/dconf/ibus.ini"
  dconf dump /com/github/libpinyin/ >"$dest/dconf/libpinyin.ini"
  dconf dump /org/gnome/desktop/input-sources/ >"$dest/dconf/input-sources.ini"
  gsettings get org.gnome.desktop.wm.keybindings switch-input-source >"$dest/gsettings/forward"
  gsettings get org.gnome.desktop.wm.keybindings switch-input-source-backward >"$dest/gsettings/backward"
  while IFS= read -r rel; do
    [[ -e $HOME/$rel || -L $HOME/$rel ]] && present+=("$rel")
  done < <(managed_paths)
  if ((${#present[@]})); then
    tar -C "$HOME" -czf "$dest/user-data.tar.gz" "${present[@]}"
  else
    tar -C "$HOME" -czf "$dest/user-data.tar.gz" --files-from /dev/null
  fi
  [[ ! -f $HOME/.config/autostart/fcitx5.desktop ]] ||
    cp -a "$HOME/.config/autostart/fcitx5.desktop" "$dest/conflicts/"
  [[ ! -f $HOME/.pam_environment ]] || cp -a "$HOME/.pam_environment" "$dest/conflicts/"
  dpkg-query -W -f='${binary:Package}\t${Version}\n' 2>/dev/null |
    awk -F '\t' '$1 ~ /^(ibus($|-)|im-config$|fonts-noto-cjk$|fonts-wqy|libpinyin)/ {
      n=$1; sub(/:[^:]+$/, "", n); print n "\t" $2
    }' | sort -u >"$dest/packages.tsv"
  cut -f1 "$dest/packages.tsv" >"$dest/packages.txt"
  printf 'created=%s\nhost=%s\nuser=%s\n' \
    "$(date --iso-8601=seconds)" "$(hostname)" "$USER" >"$dest/snapshot-info.txt"
}

remove_managed() {
  local rel
  while IFS= read -r rel; do
    [[ $rel == .* && $rel != *..* ]] || die "Unsafe managed path: $rel"
    rm -rf -- "${HOME:?}/$rel"
  done < <(managed_paths)
}

load_settings() {
  local src=$1 value ibus_file libpinyin_file sources_file
  ibus_file="$src/dconf/ibus.ini"
  libpinyin_file="$src/dconf/libpinyin.ini"
  sources_file="$src/dconf/input-sources.ini"
  [[ -e $ibus_file ]] || ibus_file="$src/dconf/org-freedesktop-ibus.ini"
  [[ -e $libpinyin_file ]] || libpinyin_file="$src/dconf/com-github-libpinyin.ini"
  [[ -e $sources_file ]] || sources_file="$src/dconf/gnome-input-sources.ini"
  dconf reset -f /org/freedesktop/ibus/
  dconf reset -f /com/github/libpinyin/
  dconf reset -f /org/gnome/desktop/input-sources/
  [[ ! -s $ibus_file ]] || dconf load /org/freedesktop/ibus/ <"$ibus_file"
  [[ ! -s $libpinyin_file ]] || dconf load /com/github/libpinyin/ <"$libpinyin_file"
  [[ ! -s $sources_file ]] || dconf load /org/gnome/desktop/input-sources/ <"$sources_file"
  if [[ -f $src/gsettings/forward ]]; then
    value=$(<"$src/gsettings/forward")
  else
    value=$(<"$src/gsettings/switch-input-source")
  fi
  gsettings set org.gnome.desktop.wm.keybindings switch-input-source "$value"
  if [[ -f $src/gsettings/backward ]]; then
    value=$(<"$src/gsettings/backward")
  else
    value=$(<"$src/gsettings/switch-input-source-backward")
  fi
  gsettings set org.gnome.desktop.wm.keybindings switch-input-source-backward "$value"
}

resolve_fcitx() {
  local file="$HOME/.pam_environment" tmp
  rm -f -- "$HOME/.config/autostart/fcitx5.desktop"
  if [[ -f $file ]] && grep -Eq '^(GTK_IM_MODULE|QT_IM_MODULE|XMODIFIERS).*fcitx' "$file"; then
    tmp=$(mktemp)
    awk '!/^(GTK_IM_MODULE|QT_IM_MODULE|XMODIFIERS)[[:space:]]+(DEFAULT=)?fcitx/' "$file" >"$tmp"
    if [[ -s $tmp ]]; then cat "$tmp" >"$file"; else rm -f -- "$file"; fi
    rm -f -- "$tmp"
  fi
}

restore_snapshot() {
  local src=$1
  stop_input_methods
  remove_managed
  tar -C "$HOME" -xzf "$src/user-data.tar.gz" --no-same-owner
  load_settings "$src"
  rm -f -- "$HOME/.config/autostart/fcitx5.desktop"
  if [[ -f $src/conflicts/fcitx5.desktop ]]; then
    mkdir -p "$HOME/.config/autostart"
    cp -a "$src/conflicts/fcitx5.desktop" "$HOME/.config/autostart/"
  fi
  [[ ! -f $src/conflicts/.pam_environment ]] ||
    cp -a "$src/conflicts/.pam_environment" "$HOME/.pam_environment"
  start_ibus
}

validate_path() {
  local entry=$1 prefix=$2
  [[ $entry == "$prefix" || $entry == "$prefix/"* ]] || die "Unexpected path: $entry"
  [[ $entry != /* && $entry != *'/../'* && $entry != '../'* && $entry != *'/..' ]] ||
    die "Unsafe archive path: $entry"
}

extract_bundle() {
  local archive=$1 work=$2 entry root
  [[ -f $archive ]] || die "Bundle not found: $archive"
  tar -tzf "$archive" >/dev/null || die "Invalid tar.gz bundle."
  while IFS= read -r entry; do validate_path "$entry" input-method-bundle; done < <(tar -tzf "$archive")
  tar -C "$work" -xzf "$archive" --no-same-owner
  root="$work/input-method-bundle"
  [[ -f $root/FORMAT && $(<"$root/FORMAT") == 1 ]] || die "Unsupported format."
  (cd "$root" && sha256sum -c CHECKSUMS >&2) || die "Checksum failure."
  while IFS= read -r entry; do
    case $entry in
      .cache/ibus/libpinyin|.cache/ibus/libpinyin/*|.local/share/libpinyin|.local/share/libpinyin/*|.config/libpinyin|.config/libpinyin/*|.xinputrc) ;;
      *) die "Unexpected user-data path: $entry" ;;
    esac
    [[ $entry != *'/../'* && $entry != '../'* ]] || die "Unsafe user-data path."
  done < <(tar -tzf "$root/user-data.tar.gz")
  printf '%s\n' "$root"
}

install_missing() {
  local file=$1 pkg
  local -a missing=()
  while IFS= read -r pkg; do
    [[ $pkg =~ ^[a-z0-9][a-z0-9+.-]*$ ]] || die "Invalid package name: $pkg"
    dpkg-query -W -f='${db:Status-Abbrev}' "$pkg" 2>/dev/null | grep -q '^ii ' || missing+=("$pkg")
  done <"$file"
  ((${#missing[@]} == 0)) && { log "All required packages are installed."; return; }
  log "Installing: ${missing[*]}"
  sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}"
}

do_export() {
  local output work root checksums_tmp
  output=${1:-"$PWD/ubuntu24-input-method-$(hostname)-$(date +%Y%m%d-%H%M%S).tar.gz"}
  [[ $output == /* ]] || output="$PWD/$output"
  [[ ! -e $output ]] || die "Refusing to overwrite $output"
  work=$(mktemp -d); trap 'rm -rf -- "$work"' EXIT
  root="$work/input-method-bundle"; mkdir -p "$root"
  stop_input_methods; capture "$root"; start_ibus
  printf '1\n' >"$root/FORMAT"
  {
    printf 'bundle_type=ubuntu-gnome-ibus-libpinyin\n'
    # shellcheck disable=SC1091
    . /etc/os-release
    printf 'source_os=%s %s\n' "$ID" "$VERSION_ID"
    printf 'source_arch=%s\n' "$(dpkg --print-architecture)"
    printf 'source_desktop=%s\n' "${XDG_CURRENT_DESKTOP:-unknown}"
  } >"$root/manifest.txt"
  checksums_tmp="$work/CHECKSUMS"
  (cd "$root" && find . -type f ! -name CHECKSUMS -print0 | sort -z | xargs -0 sha256sum) \
    >"$checksums_tmp"
  mv -- "$checksums_tmp" "$root/CHECKSUMS"
  tar -C "$work" -czf "$output" input-method-bundle
  rm -rf -- "$work"; trap - EXIT
  log "Created: $output"
}

do_import() {
  local archive=$1 work root backup applying=false
  [[ $archive == /* ]] || archive="$PWD/$archive"
  work=$(mktemp -d); trap 'rm -rf -- "$work"' EXIT
  root=$(extract_bundle "$archive" "$work")
  install_missing "$root/packages.txt"
  backup="$BACKUP_ROOT/$(date +%Y%m%d-%H%M%S)-$(hostname)/before-import"
  stop_input_methods; capture "$backup"
  rollback_error() {
    local status=$?
    trap - ERR INT TERM
    [[ $applying != true ]] || { warn "Import failed; rolling back."; restore_snapshot "$backup"; }
    exit "$status"
  }
  trap rollback_error ERR INT TERM
  applying=true
  remove_managed
  tar -C "$HOME" -xzf "$root/user-data.tar.gz" --no-same-owner
  load_settings "$root"
  resolve_fcitx
  im-config -n ibus
  start_ibus
  applying=false
  trap - ERR INT TERM
  rm -rf -- "$work"; trap - EXIT
  log "Import complete. Backup: $backup"
  log "Log out/in, then run: ./$PROGRAM check"
}

do_inspect() {
  local archive=$1 work root sources_file
  [[ $archive == /* ]] || archive="$PWD/$archive"
  work=$(mktemp -d); trap 'rm -rf -- "$work"' EXIT
  root=$(extract_bundle "$archive" "$work")
  sources_file="$root/dconf/input-sources.ini"
  [[ -f $sources_file ]] || sources_file="$root/dconf/gnome-input-sources.ini"
  printf '%s\n' '--- manifest ---'; cat "$root/manifest.txt"
  printf '%s\n' '--- packages ---'; cat "$root/packages.tsv"
  printf '%s\n' '--- input sources ---'; cat "$sources_file"
  printf '%s\n' '--- user data ---'; tar -tzf "$root/user-data.tar.gz"
  rm -rf -- "$work"; trap - EXIT
}

do_check() {
  local failed=false owner sources
  owner=$(busctl --user --no-pager list 2>/dev/null | awk '$1=="org.freedesktop.IBus"{print $3}')
  sources=$(gsettings get org.gnome.desktop.input-sources sources 2>/dev/null || true)
  [[ $owner == ibus-daemon ]] || { warn "IBus owner: ${owner:-none}"; failed=true; }
  pgrep -u "$(id -u)" -x fcitx5 >/dev/null 2>&1 && { warn "Fcitx5 is running."; failed=true; }
  [[ $sources == *"'ibus', 'libpinyin'"* ]] || { warn "LibPinyin is absent from GNOME sources."; failed=true; }
  ibus list-engine 2>/dev/null | grep -q 'libpinyin - ' || { warn "LibPinyin engine unavailable."; failed=true; }
  [[ $failed == false ]] || return 1
  log "Healthy: IBus owns the bus and LibPinyin is available."
}

do_rollback() {
  local backup=$1 safety
  [[ $backup == /* ]] || backup="$PWD/$backup"
  [[ -f $backup/user-data.tar.gz ]] || die "Invalid backup: $backup"
  safety="$BACKUP_ROOT/$(date +%Y%m%d-%H%M%S)-$(hostname)/before-rollback"
  stop_input_methods; capture "$safety"; restore_snapshot "$backup"
  log "Restored. Safety backup: $safety"
}

main() {
  local command=${1:-}; [[ -n $command ]] || { usage; exit 2; }; shift || true
  check_user; check_platform
  need tar; need dconf; need gsettings; need sha256sum
  case $command in
    export) [[ $# -le 1 ]] || die "Too many arguments."; do_export "$@" ;;
    import) [[ $# -eq 1 ]] || die "import needs one bundle."; need im-config; do_import "$@" ;;
    inspect) [[ $# -eq 1 ]] || die "inspect needs one bundle."; do_inspect "$@" ;;
    check) [[ $# -eq 0 ]] || die "check takes no arguments."; do_check ;;
    list-backups) find "$BACKUP_ROOT" -mindepth 2 -maxdepth 2 -type d 2>/dev/null | sort -r ;;
    rollback) [[ $# -eq 1 ]] || die "rollback needs one directory."; do_rollback "$@" ;;
    -h|--help|help) usage ;;
    *) die "Unknown command: $command" ;;
  esac
}
main "$@"
