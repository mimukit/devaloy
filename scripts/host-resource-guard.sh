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

  --check            Report what is and is not in place. Default. Writes nothing.
  --apply            Install and configure everything. Needs root.
  --restart-docker   With --apply, also restart dockerd so the log limits take
                     effect. This BOUNCES EVERY CONTAINER on the host. Off by
                     default; new log settings only reach containers created
                     after the restart either way.
  --yes              Skip the confirmation prompt.

Environment overrides: SWAPPINESS, LOG_MAX_SIZE, LOG_MAX_FILE,
PRUNE_KEEP_HOURS, EARLYOOM_AVOID, EARLYOOM_PREFER.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --check) MODE="check" ;;
    --apply) MODE="apply" ;;
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
