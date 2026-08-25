#!/usr/bin/env bash
# One-shot Sysbox host setup for devaloy, meant to be run via curl on a fresh
# Linux VM/VPS:
#
#   curl -fsSL https://raw.githubusercontent.com/mimukit/devaloy/main/scripts/setup-sysbox-host.sh | sudo bash
#
# It performs, in order, the whole procedure from
# docs/wiki/prepare-a-host-for-sysbox.md:
#
#   1. checks the kernel (Sysbox needs ID-mapped mounts, 5.12+; tested on 6.8+)
#   2. installs jq if missing
#   3. picks a bip and a default-address-pool in 10.x that miss every subnet
#      already in use on this host (override with --bip / --pool)
#   4. merges the two keys into /etc/docker/daemon.json (backup alongside)
#   5. restarts dockerd — THIS BOUNCES EVERY CONTAINER ON THE HOST
#   6. downloads and installs the Sysbox deb for this architecture
#   7. verifies sysbox is active and dockerd was not restarted a second time
#
# Step 5 is why this script prompts before doing anything when it finds running
# containers. On a host serving live sites, do NOT pipe this from curl: use
# scripts/host-resource-guard.sh --sysbox and take the restart as a maintenance
# window, as the wiki page describes. On a fresh VPS, --yes (or a piped stdin,
# which cannot prompt and therefore requires --yes) makes it fully unattended:
#
#   curl -fsSL .../setup-sysbox-host.sh | sudo bash -s -- --yes
set -euo pipefail

SYSBOX_VERSION="${SYSBOX_VERSION:-0.7.1}"
SYSBOX_BIP="${SYSBOX_BIP:-}"
SYSBOX_POOL="${SYSBOX_POOL:-}"
ASSUME_YES=0
DAEMON_JSON=/etc/docker/daemon.json

usage() {
  cat <<'EOF'
Usage: setup-sysbox-host.sh [--yes] [--bip CIDR] [--pool BASE/PREFIX/SIZE]

  --yes            Skip the confirmation prompt. Required when piped from curl.
  --bip CIDR       Docker default bridge address. Default: first free 10.x/16.
  --pool B/P/S     Address pool for user-defined networks, e.g.
                   10.211.0.0/16/24. Default: first free 10.x/16, size 24.

Environment overrides: SYSBOX_VERSION, SYSBOX_BIP, SYSBOX_POOL.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --yes|-y) ASSUME_YES=1 ;;
    --bip) SYSBOX_BIP="${2:?--bip needs a CIDR, e.g. 10.210.0.1/16}"; shift ;;
    --pool) SYSBOX_POOL="${2:?--pool needs BASE/PREFIX/SIZE, e.g. 10.211.0.0/16/24}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
  shift
done

ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }
die()  { printf '\n\033[31m%s\033[0m\n' "$1" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Run as root: curl -fsSL ... | sudo bash"
command -v apt-get >/dev/null 2>&1 || die "This script needs a Debian/Ubuntu host (apt-get not found)."
command -v docker >/dev/null 2>&1 || die "Docker is not installed. Install Docker first, then re-run."

# ── CIDR arithmetic (same as host-resource-guard.sh) ─────────────────────────
ip2int() {
  local IFS=. a b c d
  read -r a b c d <<<"$1"
  echo $(( (a << 24) | (b << 16) | (c << 8) | d ))
}
cidr_bounds() { # "10.0.0.1/16" -> "start end", both as integers
  local ip="${1%/*}" bits="${1#*/}" base mask start size
  base=$(ip2int "$ip")
  mask=$(( bits == 0 ? 0 : (0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF ))
  start=$(( base & mask ))
  size=$(( bits >= 32 ? 1 : (1 << (32 - bits)) ))
  echo "$start $(( start + size - 1 ))"
}
cidr_overlaps() { # two CIDRs -> exit 0 when they share any address
  local a_lo a_hi b_lo b_hi
  read -r a_lo a_hi <<<"$(cidr_bounds "$1")"
  read -r b_lo b_hi <<<"$(cidr_bounds "$2")"
  [ "$a_lo" -le "$b_hi" ] && [ "$b_lo" -le "$a_hi" ]
}
overlaps_any() { # CIDR vs the IN_USE list
  local sub
  for sub in "${IN_USE[@]:-}"; do
    [ -z "$sub" ] && continue
    case "$sub" in *:*) continue ;; esac   # IPv6, not our arithmetic
    cidr_overlaps "$1" "$sub" && return 0
  done
  return 1
}

# ── 1. Kernel ────────────────────────────────────────────────────────────────
head_ "Kernel"
KVER=$(uname -r)
KMAJ=${KVER%%.*}; KREST=${KVER#*.}; KMIN=${KREST%%.*}
if [ "$KMAJ" -gt 6 ] || { [ "$KMAJ" -eq 6 ] && [ "$KMIN" -ge 8 ]; }; then
  ok "Kernel ${KVER} — ID-mapped mounts available"
elif [ "$KMAJ" -gt 5 ] || { [ "$KMAJ" -eq 5 ] && [ "$KMIN" -ge 12 ]; }; then
  warn "Kernel ${KVER} has ID-mapped mounts but is below the 6.8 Sysbox tests on"
else
  die "Kernel ${KVER} is too old. Sysbox needs ID-mapped mounts (5.12+)."
fi

if command -v sysbox-runc >/dev/null 2>&1 && systemctl is-active --quiet sysbox 2>/dev/null; then
  ok "Sysbox is already installed and running — nothing to do"
  sysbox-runc --version 2>/dev/null | head -1 | sed 's/^/  /'
  exit 0
fi

# ── 2. jq ────────────────────────────────────────────────────────────────────
if ! command -v jq >/dev/null 2>&1; then
  head_ "Installing jq"
  apt-get update -qq
  apt-get install -y -qq jq
fi

# ── 3. Pick ranges that miss everything ──────────────────────────────────────
head_ "Subnets in use on this host"
IN_USE=()
while read -r net sub; do
  [ -z "$sub" ] && continue
  IN_USE+=("$sub")
  printf '  docker network %-28s %s\n' "$net" "$sub"
done < <(docker network ls -q 2>/dev/null | xargs -r docker network inspect \
  --format '{{.Name}} {{range .IPAM.Config}}{{.Subnet}} {{end}}' 2>/dev/null || true)
while read -r dev sub; do
  [ -z "$sub" ] && continue
  IN_USE+=("$sub")
  printf '  interface      %-28s %s\n' "$dev" "$sub"
done < <(ip -4 -o addr show 2>/dev/null | awk '$2 != "lo" {print $2, $4}')

# Honour keys already in daemon.json (a previous run, or host-resource-guard
# --sysbox --apply): reuse them rather than picking new ranges.
CUR_BIP=""; CUR_POOL_BASE=""; CUR_POOL_SIZE=""
if [ -f "$DAEMON_JSON" ]; then
  CUR_BIP=$(jq -r '.bip // empty' "$DAEMON_JSON")
  CUR_POOL_BASE=$(jq -r '.["default-address-pools"][0].base // empty' "$DAEMON_JSON")
  CUR_POOL_SIZE=$(jq -r '.["default-address-pools"][0].size // empty' "$DAEMON_JSON")
fi
WRITE_KEYS=1
if [ -n "$CUR_BIP" ] && [ -n "$CUR_POOL_BASE" ]; then
  ok "daemon.json already sets bip=${CUR_BIP} and pool=${CUR_POOL_BASE} size ${CUR_POOL_SIZE} — keeping them"
  WRITE_KEYS=0
  SYSBOX_BIP="$CUR_BIP"
  POOL_BASE="$CUR_POOL_BASE"; POOL_SIZE="$CUR_POOL_SIZE"
fi

if [ "$WRITE_KEYS" -eq 1 ]; then
  head_ "Picking address ranges"
  if [ -z "$SYSBOX_BIP" ]; then
    for n in 210 220 230 240 250; do
      if ! overlaps_any "10.${n}.0.1/16"; then SYSBOX_BIP="10.${n}.0.1/16"; break; fi
    done
    [ -n "$SYSBOX_BIP" ] || die "Could not find a free 10.x/16 for --bip. Pass --bip yourself."
  fi
  if [ -z "$SYSBOX_POOL" ]; then
    for n in 211 221 231 241 251; do
      if [ "10.${n}.0.0/16" != "${SYSBOX_BIP%.*.*}.0.0/16" ] && ! overlaps_any "10.${n}.0.0/16"; then
        SYSBOX_POOL="10.${n}.0.0/16/24"; break
      fi
    done
    [ -n "$SYSBOX_POOL" ] || die "Could not find a free 10.x/16 for --pool. Pass --pool yourself."
  fi
  POOL_BASE="${SYSBOX_POOL%/*}"          # 10.211.0.0/16
  POOL_SIZE="${SYSBOX_POOL##*/}"         # 24
  case "$POOL_BASE" in */*) ;; *) die "--pool must be BASE/PREFIX/SIZE, e.g. 10.211.0.0/16/24" ;; esac
  if overlaps_any "$SYSBOX_BIP"; then die "bip ${SYSBOX_BIP} overlaps a subnet already in use here."; fi
  if overlaps_any "$POOL_BASE"; then die "pool ${POOL_BASE} overlaps a subnet already in use here."; fi
  if cidr_overlaps "$SYSBOX_BIP" "$POOL_BASE"; then die "bip ${SYSBOX_BIP} overlaps pool ${POOL_BASE}."; fi
  ok "bip  = ${SYSBOX_BIP}"
  ok "pool = ${POOL_BASE} size ${POOL_SIZE}"
fi

# ── Confirm before the disruptive part ───────────────────────────────────────
RUNNING=$(docker ps -q 2>/dev/null | wc -l | tr -d ' ')
head_ "About to apply"
printf '  write bip/default-address-pools to %s (merge, with backup)\n' "$DAEMON_JSON"
printf '  restart dockerd — %s running container(s) on this host will bounce\n' "$RUNNING"
printf '  install sysbox-ce %s\n' "$SYSBOX_VERSION"
if [ "$RUNNING" -gt 0 ]; then
  warn "This host is not empty. If it serves live sites, stop here and follow"
  warn "docs/wiki/prepare-a-host-for-sysbox.md step by step instead."
fi
if [ "$ASSUME_YES" -ne 1 ]; then
  if [ ! -t 0 ]; then
    die "stdin is not a terminal, so this script cannot prompt. Re-run with --yes: curl ... | sudo bash -s -- --yes"
  fi
  printf '\nContinue? [y/N] '
  read -r reply
  case "$reply" in [yY]*) ;; *) echo "Aborted."; exit 1 ;; esac
fi

# ── 4. Write daemon.json ─────────────────────────────────────────────────────
if [ "$WRITE_KEYS" -eq 1 ]; then
  head_ "Writing ${DAEMON_JSON}"
  if [ -f "$DAEMON_JSON" ]; then
    cp -a "$DAEMON_JSON" "${DAEMON_JSON}.bak.$(date +%Y%m%d%H%M%S)"
  else
    mkdir -p /etc/docker
    echo '{}' > "$DAEMON_JSON"
  fi
  TMP=$(mktemp)
  # Merge, never replace: Dokploy and host-resource-guard.sh keep their own
  # keys in this file.
  jq --arg bip "$SYSBOX_BIP" --arg base "$POOL_BASE" --argjson size "$POOL_SIZE" \
    '.bip = $bip | .["default-address-pools"] = [{"base": $base, "size": $size}]' \
    "$DAEMON_JSON" > "$TMP"
  mv "$TMP" "$DAEMON_JSON"
  chmod 644 "$DAEMON_JSON"
  ok "Written (backup alongside)"
fi

# ── 5. Restart dockerd ───────────────────────────────────────────────────────
head_ "Restarting dockerd"
systemctl restart docker
ok "dockerd restarted"
DOCKER_STARTED=$(systemctl show docker --property=ActiveEnterTimestamp --value)

# ── 6. Install Sysbox ────────────────────────────────────────────────────────
head_ "Installing Sysbox ${SYSBOX_VERSION}"
ARCH=$(dpkg --print-architecture)
DEB="sysbox-ce_${SYSBOX_VERSION}.linux_${ARCH}.deb"
URL="https://github.com/nestybox/sysbox/releases/download/v${SYSBOX_VERSION}/${DEB}"
TMPDIR_DEB=$(mktemp -d)
trap 'rm -rf "$TMPDIR_DEB"' EXIT
curl -fsSL -o "${TMPDIR_DEB}/${DEB}" "$URL"
apt-get install -y "${TMPDIR_DEB}/${DEB}"

# ── 7. Verify ────────────────────────────────────────────────────────────────
head_ "Verifying"
if systemctl is-active --quiet sysbox; then
  ok "sysbox is active ($(sysbox-runc --version 2>/dev/null | head -1))"
else
  die "sysbox is not active after install. Check: systemctl status sysbox"
fi
DOCKER_STARTED_NOW=$(systemctl show docker --property=ActiveEnterTimestamp --value)
if [ "$DOCKER_STARTED" = "$DOCKER_STARTED_NOW" ]; then
  ok "dockerd was not restarted a second time by the installer"
else
  warn "dockerd restarted again during the install (the two keys were probably"
  warn "not in place when the installer looked). Confirm your services are up."
fi
if docker info --format '{{json .Runtimes}}' 2>/dev/null | grep -q sysbox-runc; then
  ok "docker reports the sysbox-runc runtime"
else
  warn "docker does not list sysbox-runc yet — check /etc/docker/daemon.json and dockerd logs"
fi

cat <<EOF

Done. To turn it on for devaloy, set on the stack (Dokploy Environment tab,
or .env for a hand-run stack):

  WITH_DOCKER=true
  DEVALOY_RUNTIME=sysbox-runc

Then redeploy WITH A REBUILD — WITH_DOCKER is a build argument. The boot log
should show:

  [entrypoint] Docker daemon ready — logs in /var/log/dockerd.log
EOF
