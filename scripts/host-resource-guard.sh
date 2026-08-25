#!/usr/bin/env bash
# Sets up the HOST-side half of the resource story: the parts that cannot live
# in a compose file. Container ceilings come from mem_limit/cpus/pids_limit in
# each stack's own compose (see docs/wiki/vm-resource-limits.md); this covers
# what those cannot reach.
#
#   earlyoom        kills one process before the box thrashes itself unreachable
#   swappiness      biases the kernel toward RAM until there is real pressure
#   log rotation    stops json-file logs from filling the disk
#   prune timer     stops Dokploy's build cache from filling the disk
#
# Safe by default: with no arguments it only REPORTS. Nothing is written until
# you pass --apply.
set -euo pipefail

MODE="check"
ASSUME_YES=0
RESTART_DOCKER=0
SYSBOX=0

# --sysbox ranges. NO DEFAULTS, on purpose. A script that picks network ranges
# for a host serving live sites is the failure mode, not the convenience: the
# ranges have to miss whatever Dokploy already allocated, and only --sysbox
# --check on that host can tell you what that is.
SYSBOX_BIP="${SYSBOX_BIP:-}"
SYSBOX_POOL="${SYSBOX_POOL:-}"
# Matches what the plan's Phase 0 spike installed and verified.
SYSBOX_VERSION="${SYSBOX_VERSION:-0.7.1}"

SWAPPINESS="${SWAPPINESS:-10}"
LOG_MAX_SIZE="${LOG_MAX_SIZE:-10m}"
LOG_MAX_FILE="${LOG_MAX_FILE:-3}"
PRUNE_KEEP_HOURS="${PRUNE_KEEP_HOURS:-168}"

# Processes earlyoom must never pick. Killing any of these costs you the box or
# the data: sshd and tailscaled are how you get in, dockerd/containerd own every
# container, traefik is the only thing routing traffic, mariadbd holds the sites.
EARLYOOM_AVOID="${EARLYOOM_AVOID:-^(sshd|dockerd|containerd|tailscaled|traefik|mariadbd|mysqld)$}"
# Processes it should pick first. apache2 is a WordPress worker (this image is
# mod_php under Apache, not php-fpm); node is an agent session or a build. Both
# are cheap to lose and come back on their own.
EARLYOOM_PREFER="${EARLYOOM_PREFER:-^(apache2|node|npm|pnpm|turbo|esbuild)$}"

DAEMON_JSON=/etc/docker/daemon.json
SYSCTL_FILE=/etc/sysctl.d/99-devaloy-resources.conf
EARLYOOM_DEFAULTS=/etc/default/earlyoom
PRUNE_SERVICE=/etc/systemd/system/docker-prune.service
PRUNE_TIMER=/etc/systemd/system/docker-prune.timer

usage() {
  cat <<'EOF'
Usage: host-resource-guard.sh [--check|--apply] [--restart-docker] [--yes]
       host-resource-guard.sh --sysbox [--check|--apply] [--bip CIDR]
                              [--pool BASE/SIZE] [--restart-docker] [--yes]

  --check            Report what is and is not in place. Default. Writes nothing.
  --apply            Install and configure everything. Needs root.
  --restart-docker   With --apply, also restart dockerd so the log limits take
                     effect. This BOUNCES EVERY CONTAINER on the host. Off by
                     default; new log settings only reach containers created
                     after the restart either way.
  --yes              Skip the confirmation prompt.

Sysbox mode (--sysbox) prepares this host to run devaloy with
DEVALOY_RUNTIME=sysbox-runc, which is what lets devaloy run a nested Docker
daemon with no privileged flag. It does two things and no more: it reports what
the host's networks and daemon.json look like now, and on --apply it writes the
`bip` and `default-address-pools` keys the Sysbox installer would otherwise pick
for you. It never installs the deb and never removes a container.

  --bip CIDR         The Docker default bridge address, e.g. 10.210.0.1/16
  --pool BASE/SIZE   The pool user-defined networks come from, e.g.
                     10.211.0.0/16/24 — that is BASE/PREFIX/SIZE.

Both are required for --sysbox --apply and have no defaults. Run
--sysbox --check first: it prints every subnet in use on this host so you can
pick ranges that miss them.

Environment overrides: SWAPPINESS, LOG_MAX_SIZE, LOG_MAX_FILE,
PRUNE_KEEP_HOURS, EARLYOOM_AVOID, EARLYOOM_PREFER, SYSBOX_BIP, SYSBOX_POOL,
SYSBOX_VERSION.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --check) MODE="check" ;;
    --apply) MODE="apply" ;;
    --sysbox) SYSBOX=1 ;;
    --bip) SYSBOX_BIP="${2:?--bip needs a CIDR, e.g. 10.210.0.1/16}"; shift ;;
    --pool) SYSBOX_POOL="${2:?--pool needs BASE/PREFIX/SIZE, e.g. 10.211.0.0/16/24}"; shift ;;
    --restart-docker) RESTART_DOCKER=1 ;;
    --yes|-y) ASSUME_YES=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
  shift
done

ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

if [ "$MODE" = "apply" ] && [ "$(id -u)" -ne 0 ]; then
  echo "Run --apply with sudo." >&2
  exit 1
fi

# ── Sysbox ───────────────────────────────────────────────────────────────────
# Everything under --sysbox lives here and returns. It shares this file with the
# resource guard for one reason: both write /etc/docker/daemon.json, and two
# scripts merging the same file is how the log limits above quietly disappear.
# One writer, one merge path.

# IPv4 CIDR arithmetic, so the overlap check below is a real check rather than a
# string comparison on the first two octets.
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
  local a b
  read -r a_lo a_hi <<<"$(cidr_bounds "$1")"
  read -r b_lo b_hi <<<"$(cidr_bounds "$2")"
  [ "$a_lo" -le "$b_hi" ] && [ "$b_lo" -le "$a_hi" ]
}

sysbox_deb="sysbox-ce_${SYSBOX_VERSION}.linux_$(dpkg --print-architecture 2>/dev/null || echo amd64).deb"
sysbox_url="https://github.com/nestybox/sysbox/releases/download/v${SYSBOX_VERSION}/${sysbox_deb}"

if [ "$SYSBOX" -eq 1 ]; then
  head_ "Sysbox prerequisites"

  KVER=$(uname -r)
  KMAJ=${KVER%%.*}; KREST=${KVER#*.}; KMIN=${KREST%%.*}
  if [ "$KMAJ" -gt 6 ] || { [ "$KMAJ" -eq 6 ] && [ "$KMIN" -ge 8 ]; }; then
    ok "Kernel ${KVER} — ID-mapped mounts available, no shiftfs needed"
  elif [ "$KMAJ" -gt 5 ] || { [ "$KMAJ" -eq 5 ] && [ "$KMIN" -ge 12 ]; }; then
    warn "Kernel ${KVER} has ID-mapped mounts but is below the 6.8 Sysbox tests on"
  else
    bad "Kernel ${KVER} is too old — Sysbox needs ID-mapped mounts (5.12+) or shiftfs"
  fi

  if command -v sysbox-runc >/dev/null 2>&1; then
    if systemctl is-active --quiet sysbox 2>/dev/null; then
      ok "sysbox installed and running ($(sysbox-runc --version 2>/dev/null | head -1))"
    else
      bad "sysbox installed but not running — systemctl status sysbox"
    fi
  else
    bad "sysbox not installed — see the install line at the end of this report"
  fi

  command -v jq >/dev/null 2>&1 && ok "jq present (the Sysbox installer uses it)" \
    || bad "jq not installed — both this script and the Sysbox installer need it"

  head_ "What ${DAEMON_JSON} says now"
  CUR_BIP=""; CUR_POOLS=""
  if [ -f "$DAEMON_JSON" ] && command -v jq >/dev/null 2>&1; then
    CUR_BIP=$(jq -r '.bip // empty' "$DAEMON_JSON")
    CUR_POOLS=$(jq -r '(.["default-address-pools"] // []) | map("\(.base) size \(.size)") | join(", ")' "$DAEMON_JSON")
  fi
  # These two keys are the whole point of --sysbox --apply. The Sysbox installer
  # sets them itself if they are absent, and it restarts dockerd to do it, which
  # bounces every container on the host. Present beforehand, it leaves them and
  # skips that restart.
  [ -n "$CUR_BIP" ] && ok "bip = ${CUR_BIP}" \
    || bad "no bip — the Sysbox installer will pick one and restart dockerd to apply it"
  [ -n "$CUR_POOLS" ] && ok "default-address-pools = ${CUR_POOLS}" \
    || bad "no default-address-pools — same restart, same reason"

  head_ "Subnets in use on this host"
  printf '  Pick ranges that miss every line below.\n\n'
  IN_USE=()
  if command -v docker >/dev/null 2>&1; then
    while read -r net sub; do
      [ -z "$sub" ] && continue
      IN_USE+=("$sub")
      printf '  docker network %-28s %s\n' "$net" "$sub"
    done < <(docker network ls -q 2>/dev/null | xargs -r docker network inspect \
      --format '{{.Name}} {{range .IPAM.Config}}{{.Subnet}} {{end}}' 2>/dev/null || true)
  fi
  while read -r dev sub; do
    [ -z "$sub" ] && continue
    IN_USE+=("$sub")
    printf '  interface      %-28s %s\n' "$dev" "$sub"
  done < <(ip -4 -o addr show 2>/dev/null | awk '$2 != "lo" {print $2, $4}')

  if [ "$MODE" = "check" ]; then
    cat <<EOF

Report only. Nothing was written.

To prepare this host, in this order:

  1. Pick a bip and a pool that miss every subnet listed above. Anywhere in
     10.x is usually free on a Dokploy host, which allocates from 172.16/12.

  2. Write them, still without restarting anything:

       sudo $0 --sysbox --apply --bip 10.210.0.1/16 --pool 10.211.0.0/16/24

  3. Restart dockerd at a time you choose. THIS BOUNCES EVERY CONTAINER ON
     THIS HOST, so treat it as a maintenance window and confirm every service
     came back before continuing:

       sudo systemctl restart docker

  4. Only then install Sysbox. With the two keys already in place it leaves
     them alone and does not restart dockerd a second time:

       curl -fsSLO ${sysbox_url}
       sudo apt-get install -y ./${sysbox_deb}

  5. Confirm, and check that dockerd's start time did not move:

       systemctl status sysbox
       systemctl show docker --property=ActiveEnterTimestamp

Then set WITH_DOCKER=true and DEVALOY_RUNTIME=sysbox-runc on the devaloy stack
and redeploy with a rebuild.
EOF
    exit 0
  fi

  # ── Sysbox apply ───────────────────────────────────────────────────────────
  head_ "Applying Sysbox address configuration"

  if [ -z "$SYSBOX_BIP" ] || [ -z "$SYSBOX_POOL" ]; then
    echo "Both --bip and --pool are required, and there are no defaults." >&2
    echo "Run --sysbox --check first: it lists every subnet already in use here." >&2
    exit 1
  fi
  command -v jq >/dev/null 2>&1 || { echo "jq is required. apt-get install -y jq" >&2; exit 1; }

  POOL_BASE="${SYSBOX_POOL%/*}"          # 10.211.0.0/16
  POOL_SIZE="${SYSBOX_POOL##*/}"         # 24
  case "$POOL_BASE" in */*) ;; *) echo "--pool must be BASE/PREFIX/SIZE, e.g. 10.211.0.0/16/24" >&2; exit 1 ;; esac

  # Refuse to write ranges that collide with something already on this host.
  # Getting this wrong on a box serving live sites breaks their networking, and
  # it presents as DNS failures rather than as a routing error.
  COLLIDE=0
  for sub in "${IN_USE[@]:-}"; do
    [ -z "$sub" ] && continue
    case "$sub" in *:*) continue ;; esac   # IPv6, not our arithmetic
    if cidr_overlaps "$SYSBOX_BIP" "$sub"; then
      bad "bip ${SYSBOX_BIP} overlaps ${sub}, already in use here"; COLLIDE=1
    fi
    if cidr_overlaps "$POOL_BASE" "$sub"; then
      bad "pool ${POOL_BASE} overlaps ${sub}, already in use here"; COLLIDE=1
    fi
  done
  if [ "$COLLIDE" -eq 1 ]; then
    echo >&2
    echo "Refusing to write. Pick ranges that miss the subnets above." >&2
    exit 1
  fi
  ok "${SYSBOX_BIP} and ${POOL_BASE} miss every subnet in use here"

  if [ "$ASSUME_YES" -ne 1 ]; then
    printf '\nThis writes ONLY these two keys into %s:\n' "$DAEMON_JSON"
    printf '  bip                   = %s\n' "$SYSBOX_BIP"
    printf '  default-address-pools = %s size %s\n' "$POOL_BASE" "$POOL_SIZE"
    printf 'It does not restart dockerd, install Sysbox, or touch any container.\n'
    printf 'Continue? [y/N] '
    read -r reply
    case "$reply" in [yY]*) ;; *) echo "Aborted."; exit 1 ;; esac
  fi

  if [ -f "$DAEMON_JSON" ]; then
    cp -a "$DAEMON_JSON" "${DAEMON_JSON}.bak.$(date +%Y%m%d%H%M%S)"
  else
    mkdir -p /etc/docker
    echo '{}' > "$DAEMON_JSON"
  fi
  TMP=$(mktemp)
  # Merge, never replace. Dokploy and the resource-guard section above both keep
  # their own keys in this file.
  jq --arg bip "$SYSBOX_BIP" --arg base "$POOL_BASE" --argjson size "$POOL_SIZE" \
    '.bip = $bip | .["default-address-pools"] = [{"base": $base, "size": $size}]' \
    "$DAEMON_JSON" > "$TMP"
  mv "$TMP" "$DAEMON_JSON"
  chmod 644 "$DAEMON_JSON"
  ok "Written to ${DAEMON_JSON} (backup alongside)"

  if [ "$RESTART_DOCKER" -eq 1 ]; then
    warn "Restarting dockerd — every container on this host is about to bounce."
    systemctl restart docker
    ok "dockerd restarted"
  else
    warn "dockerd NOT restarted, so these keys are not live yet. Restart it at a"
    warn "time you choose: systemctl restart docker"
  fi

  cat <<EOF

Sysbox itself is NOT installed by this script, deliberately. Installing a runc
replacement on a host serving live sites is a decision, not a side effect. Once
dockerd has restarted and every service is back:

  curl -fsSLO ${sysbox_url}
  sudo apt-get install -y ./${sysbox_deb}

With the two keys above already in place the installer leaves them alone and
does not restart dockerd again. Confirm that:

  systemctl status sysbox
  systemctl show docker --property=ActiveEnterTimestamp
EOF
  exit 0
fi

# ── Report ───────────────────────────────────────────────────────────────────

head_ "Host"
TOTAL_MB=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)
SWAP_MB=$(awk '/SwapTotal/ {printf "%d", $2/1024}' /proc/meminfo)
printf '  RAM %s MiB · swap %s MiB · %s vCPU\n' "$TOTAL_MB" "$SWAP_MB" "$(nproc)"

if [ "$SWAP_MB" -eq 0 ]; then
  bad "No swap. A memory spike goes straight to the OOM killer with no cushion."
else
  ok "Swap present (${SWAP_MB} MiB)"
fi

CGROUP_VER=$(stat -fc %T /sys/fs/cgroup/ 2>/dev/null || echo unknown)
if [ "$CGROUP_VER" = "cgroup2fs" ]; then
  ok "cgroup v2 — memswap_limit works, mem_swappiness does not"
else
  warn "cgroup v1 ($CGROUP_VER) — per-container swap behaves differently"
fi

head_ "Disk"
df -h / | awk 'NR==2 {printf "  / is %s of %s used (%s), %s free\n", $3, $2, $5, $4}'
USE_PCT=$(df --output=pcent / | tail -1 | tr -dc '0-9')
if [ "$USE_PCT" -ge 85 ]; then
  bad "Root filesystem at ${USE_PCT}%. A full disk corrupts MariaDB and wedges dockerd."
elif [ "$USE_PCT" -ge 70 ]; then
  warn "Root filesystem at ${USE_PCT}%. Worth pruning before it becomes urgent."
else
  ok "Root filesystem at ${USE_PCT}%"
fi

head_ "Controls"

if command -v earlyoom >/dev/null 2>&1; then
  if systemctl is-active --quiet earlyoom 2>/dev/null; then
    ok "earlyoom installed and running"
  else
    bad "earlyoom installed but not running"
  fi
else
  bad "earlyoom not installed — nothing stops a swap-thrash lockup"
fi

CURRENT_SWAPPINESS=$(cat /proc/sys/vm/swappiness)
if [ "$CURRENT_SWAPPINESS" -le 20 ]; then
  ok "vm.swappiness = ${CURRENT_SWAPPINESS}"
else
  warn "vm.swappiness = ${CURRENT_SWAPPINESS} (want ${SWAPPINESS}; the default 60 swaps too eagerly)"
fi

if [ -f "$DAEMON_JSON" ] && grep -q 'max-size' "$DAEMON_JSON" 2>/dev/null; then
  ok "Docker log rotation configured"
else
  bad "Docker logs are uncapped — json-file grows without limit"
fi

if systemctl is-enabled --quiet docker-prune.timer 2>/dev/null; then
  ok "Weekly docker prune timer enabled"
else
  bad "No prune timer — build cache accumulates on every deploy"
fi

if command -v docker >/dev/null 2>&1; then
  head_ "Container ceilings"
  UNLIMITED=0
  mapfile -t RUNNING < <(docker ps -q 2>/dev/null || true)
  if [ "${#RUNNING[@]}" -gt 0 ]; then
    while read -r name mem; do
      [ -z "$name" ] && continue
      if [ "$mem" = "0" ]; then
        bad "${name#/} has no memory limit"
        UNLIMITED=$((UNLIMITED + 1))
      else
        ok "${name#/} limited to $((mem / 1024 / 1024)) MiB"
      fi
    done < <(docker inspect --format '{{.Name}} {{.HostConfig.Memory}}' "${RUNNING[@]}" 2>/dev/null || true)
  fi
  if [ "$UNLIMITED" -gt 0 ]; then
    printf '\n  %s container(s) can still consume the whole host.\n' "$UNLIMITED"
    printf '  Fix those in their own compose files, not here.\n'
  fi

  head_ "Docker disk usage"
  docker system df 2>/dev/null | sed 's/^/  /' || true
fi

if [ "$MODE" = "check" ]; then
  printf '\nReport only. Re-run with --apply (as root) to fix the ✗ items above.\n'
  exit 0
fi

# ── Apply ────────────────────────────────────────────────────────────────────

head_ "Applying"

if [ "$ASSUME_YES" -ne 1 ]; then
  printf '\nThis will install earlyoom, set vm.swappiness=%s, add log rotation to\n' "$SWAPPINESS"
  printf '%s, and install a weekly docker prune timer.\n' "$DAEMON_JSON"
  [ "$RESTART_DOCKER" -eq 1 ] && printf 'It will ALSO restart dockerd, bouncing every container on this host.\n'
  printf 'Continue? [y/N] '
  read -r reply
  case "$reply" in [yY]*) ;; *) echo "Aborted."; exit 1 ;; esac
fi

# earlyoom. The backstop for everything cgroup limits cannot see: page cache,
# kernel slab, a host process, or a limit sized wrong. It acts while the box is
# still responsive, which the kernel's own OOM killer does not.
if ! command -v earlyoom >/dev/null 2>&1; then
  echo "Installing earlyoom..."
  apt-get update -qq
  apt-get install -y -qq earlyoom
fi

cat > "$EARLYOOM_DEFAULTS" <<EOF
# Managed by devaloy scripts/host-resource-guard.sh
# -m 8: act when available memory drops below 8%.
# -s 10: act when free SWAP drops below 10%. This is the one that matters on a
#        box with swap — it fires as thrashing starts, not after the box is
#        already unreachable.
EARLYOOM_ARGS="-m 8 -s 10 -r 3600 --avoid '${EARLYOOM_AVOID}' --prefer '${EARLYOOM_PREFER}'"
EOF
systemctl enable --now earlyoom >/dev/null 2>&1
systemctl restart earlyoom
ok "earlyoom configured and running"

# swappiness. Low, deliberately: swap is there to catch cold pages under real
# pressure, not to page out things that are still in use.
cat > "$SYSCTL_FILE" <<EOF
# Managed by devaloy scripts/host-resource-guard.sh
vm.swappiness = ${SWAPPINESS}
vm.vfs_cache_pressure = 50
EOF
sysctl -q --system
ok "vm.swappiness = ${SWAPPINESS}"

# Docker log rotation. Merged rather than overwritten: Dokploy and others put
# their own keys in this file and clobbering it breaks them.
if command -v jq >/dev/null 2>&1; then
  if [ -f "$DAEMON_JSON" ]; then
    cp -a "$DAEMON_JSON" "${DAEMON_JSON}.bak.$(date +%Y%m%d%H%M%S)"
  else
    mkdir -p /etc/docker
    echo '{}' > "$DAEMON_JSON"
  fi
  TMP=$(mktemp)
  jq --arg s "$LOG_MAX_SIZE" --arg f "$LOG_MAX_FILE" \
    '.["log-driver"] = "json-file" | .["log-opts"] = ((.["log-opts"] // {}) + {"max-size": $s, "max-file": $f})' \
    "$DAEMON_JSON" > "$TMP"
  mv "$TMP" "$DAEMON_JSON"
  chmod 644 "$DAEMON_JSON"
  ok "Log rotation written to ${DAEMON_JSON} (backup alongside)"
else
  warn "jq not installed — skipping ${DAEMON_JSON}. Install jq and re-run, or edit it by hand."
fi

# Weekly prune. Note what is NOT here: --volumes. Volumes hold wp-content and
# the MariaDB data directories, and pruning them would delete the sites.
cat > "$PRUNE_SERVICE" <<EOF
[Unit]
Description=Prune unused Docker images and build cache
Documentation=https://github.com/mimukit/devaloy

[Service]
Type=oneshot
# Deliberately no --volumes: named volumes hold live site data.
ExecStart=/usr/bin/docker system prune -af --filter until=${PRUNE_KEEP_HOURS}h
ExecStart=/usr/bin/docker builder prune -af --filter until=${PRUNE_KEEP_HOURS}h
EOF

cat > "$PRUNE_TIMER" <<'EOF'
[Unit]
Description=Weekly Docker prune

[Timer]
OnCalendar=Sun 04:00
Persistent=true
RandomizedDelaySec=30m

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now docker-prune.timer >/dev/null 2>&1
ok "Weekly prune timer enabled (keeps anything newer than ${PRUNE_KEEP_HOURS}h)"

if [ "$RESTART_DOCKER" -eq 1 ]; then
  echo "Restarting dockerd..."
  systemctl restart docker
  ok "dockerd restarted"
else
  warn "dockerd NOT restarted. Log rotation reaches containers created after a"
  warn "restart, so run 'systemctl restart docker' during a maintenance window."
fi

printf '\nDone. Re-run with --check to confirm, and set the per-container limits\n'
printf 'in each stack compose file if --check still reports unlimited containers.\n'
