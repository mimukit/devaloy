# shellcheck shell=bash
# PUT_CHANGED, APT_FRESH and OS_* are read by the files that source this one.
# shellcheck disable=SC2034
#
# The helpers of the system install: the layer that puts packages, apt repos,
# the dev user, the CLI and the build flags on a box. The Dockerfile runs it at
# build time through lib/system/install.sh, and scripts/install-native.sh
# sources it at install time. One copy, so the image and a native VM cannot
# drift apart on what a box carries.
#
# Sourced, never run. Bash only: the Dockerfile calls it through bash, not the
# /bin/sh its RUN lines default to.

# SYS_ROOT puts every file this layer writes under another root. The
# Dockerfile's fetch stage sets it, so the repo files land in /out and the
# final stage COPYs them, with no curl in the final image. Empty means /.
SYS_ROOT="${SYS_ROOT:-}"

sys_ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
sys_warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
sys_die()  { printf '\n\033[31m%s\033[0m\n' "$1" >&2; exit 1; }

# --- writing files only when they change -------------------------------------
#
# The whole idempotence contract of the native installer rests on these two. A
# file is replaced only when its bytes or its mode differ, through a temp file
# in the same directory and a rename, so a reader never sees half a file and an
# unchanged file keeps its mtime. PUT_CHANGED tells the caller whether anything
# moved, which is what decides a daemon-reload or a docker restart.
PUT_CHANGED=0

put_file() { # put_file SRC DEST MODE
  local src="$1" dest="$2" mode="$3" tmp
  PUT_CHANGED=0
  if [ -f "${dest}" ] && [ ! -L "${dest}" ] && cmp -s "${src}" "${dest}" &&
     [ "$(stat -c %a "${dest}")" = "${mode#0}" ]; then
    return 0
  fi
  mkdir -p "$(dirname "${dest}")"
  tmp="$(mktemp "${dest}.devaloy-XXXXXX")"
  cat "${src}" > "${tmp}"
  chmod "${mode}" "${tmp}"
  mv -f "${tmp}" "${dest}"
  PUT_CHANGED=1
}

# Feed it with `put_content DEST MODE < <(cmd)`, never `cmd | put_content`:
# the right side of a pipe runs in a subshell, and PUT_CHANGED would be set
# there and lost.
put_content() { # put_content DEST MODE, content on stdin
  local tmp
  tmp="$(mktemp)"
  cat > "${tmp}"
  put_file "${tmp}" "$1" "$2"
  rm -f "${tmp}"
}

fetch_to() { # fetch_to URL DEST MODE — download, then put_file
  local tmp
  tmp="$(mktemp)"
  curl -fsSL --retry 3 "$1" -o "${tmp}"
  put_file "${tmp}" "$2" "$3"
  rm -f "${tmp}"
}

# --- apt -----------------------------------------------------------------------
#
# `apt-get update` runs only when a package is actually missing, and once per
# run unless a repo file changed since (a caller sets APT_FRESH=0 then), so a
# re-run on a converged box makes no apt call at all. The lock timeout covers a
# cloud image whose unattended-upgrades is still running from first boot.
# NEEDRESTART_MODE=l makes Ubuntu's needrestart list the daemons an upgrade
# touched instead of restarting them: a restarted tailscaled would cut the
# Tailscale SSH session the native installer may be running in.
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l
APT_FRESH=0
APT=(apt-get -q -o DPkg::Lock::Timeout=600)

pkg_list() { # pkg_list FILE — the package names, comments and blanks stripped
  sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$1"
}

pkg_skip() { # pkg_skip [NAME...] — stdin less the lines equal to a NAME
  local n args=()
  for n in "$@"; do args+=(-e "${n}"); done
  if [ "${#args[@]}" -eq 0 ]; then cat; else grep -vxF "${args[@]}" || true; fi
}

apt_ensure() { # apt_ensure PKG...
  local p missing=()
  for p in "$@"; do
    dpkg-query -W -f='${db:Status-Status}' "${p}" 2>/dev/null | grep -qx installed ||
      missing+=("${p}")
  done
  [ "${#missing[@]}" -gt 0 ] || return 0
  if [ "${APT_FRESH}" -eq 0 ]; then
    "${APT[@]}" update </dev/null
    APT_FRESH=1
  fi
  "${APT[@]}" install -y --no-install-recommends "${missing[@]}" </dev/null
  sys_ok "installed: ${missing[*]}"
}

# --- the distro ----------------------------------------------------------------
#
# The apt repos of Tailscale and Docker are laid out by distro and codename:
# pkgs.tailscale.com/stable/<id>/<codename> and
# download.docker.com/linux/<id> <codename>. Both serve ubuntu/noble and
# debian/trixie. Which releases devaloy supports is not decided here: the
# native installer's preflight refuses any other release before it writes
# anything, and the image is always ubuntu:24.04.
OS_ID=""
OS_CODENAME=""

sys_distro() {
  [ -r /etc/os-release ] || sys_die "/etc/os-release is missing; cannot tell which distro this is."
  OS_ID="$(sed -n 's/^ID=//p' /etc/os-release | tr -d '"')"
  OS_CODENAME="$(sed -n 's/^VERSION_CODENAME=//p' /etc/os-release | tr -d '"')"
  [ -n "${OS_ID}" ] && [ -n "${OS_CODENAME}" ] ||
    sys_die "/etc/os-release names no ID or VERSION_CODENAME."
}
