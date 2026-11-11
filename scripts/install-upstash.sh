#!/usr/bin/env bash
# Install devaloy on an Upstash Box (Node runtime), meant to be run as the box
# user via curl, not with sudo:
#
#   curl -fsSL https://raw.githubusercontent.com/mimukit/devaloy/main/scripts/install-upstash.sh | bash
#
# For a branch or a tag, put the ref in both places:
#
#   curl -fsSL https://raw.githubusercontent.com/mimukit/devaloy/<ref>/scripts/install-upstash.sh | DEVALOY_REF=<ref> bash
#
# The Upstash twin of install-native.sh, with the same output shape and the
# same idempotence contract. It runs the same system steps (lib/system/) and
# the same boot steps (lib/steps/), through lib/steps/upstash-boot.sh, which
# is also the box's Upstash init command and so runs again on every container
# start. What is left in this file is what only this runtime needs at install
# time. In order:
#
#   1. preflight: not root, an Upstash Box on the Node runtime, `sudo -n`,
#      /workspace writable, Debian 12 or newer, x86_64 or aarch64, and a route
#      to github.com
#   2. clone the repo to /workspace/devaloy at DEVALOY_REF (default main), or
#      fetch and check out that ref when the clone is already there
#   3. merge the environment into /workspace/.devaloy/env (the box user, 0600)
#   4. run upstash-boot.sh in the foreground, which streams its log, until the
#      toolchain is ready and the T3 Code server is started
#   5. the SDK step: set the box's init command to the detached boot, and
#      open the public URL for port 3773 (skipped with --no-sdk)
#   6. print the preview URL, the first pairing link and the next steps
#
# A second run with the same inputs changes no file under /workspace apart
# from logs, boot-status and the toolchain's own state. A re-run is also how
# to change anything: set the variable, run the one-liner again.
set -euo pipefail

umask 022

DEVALOY_DIR=/workspace/devaloy
# The clone source. Only tests set it (scripts/upstash-lookalike.sh puts a
# snapshot of the working tree at /srv/devaloy), because a branch under test
# is not on GitHub yet. Used for the first clone, and on a re-run only when
# set, so a normal re-run never rewrites origin.
DEVALOY_SRC="${DEVALOY_SRC:-}"
DEVALOY_URL="https://github.com/mimukit/devaloy.git"
UPSTASH_DIR=/workspace/.devaloy
ENV_FILE="${UPSTASH_DIR}/env"
BOOT="${DEVALOY_DIR}/lib/steps/upstash-boot.sh"
BOOT_CMD="bash ${BOOT} --detach"
T3CODE_PORT=3773
UPSTASH_BOX_SDK="@upstash/box@0.7.10"

# The slim toolset default for this runtime (DEVALOY_SLIM, the Disk row of
# plan 0016). PHASE 1 SETS THIS from the disk the full toolset takes on a real
# box: true when it plus 4G for repos does not fit in /workspace. The env file
# overrides it either way.
DEVALOY_SLIM_DEFAULT=false

CLI_ONLY=0
SDK_ONLY=0
NO_SDK=0

usage() {
  cat <<'EOF'
Usage: install-upstash.sh [--no-sdk | --sdk-only | --cli-only]

  --no-sdk     Install and boot, but leave the init command and the public
               URL alone (no API key needed).
  --sdk-only   Only the SDK step: set the init command and open the public
               URL. Run this after a snapshot restore onto a new box.
  --cli-only   Reinstall the devaloy CLI and lib/ from /workspace/devaloy and
               stop. `devaloy update` runs this after its git pull.

Environment (a non-empty value overwrites the one in /workspace/.devaloy/env;
an empty or unset one keeps it):

  UPSTASH_BOX_API_KEY   Upstash API key for the SDK step (asked for on the
                        terminal when missing; never written to disk)
  DEVALOY_REF           branch or tag to install, default main
  WITH_TAILSCALE        true: userspace tailscaled and Tailscale SSH
  TS_AUTHKEY            Tailscale auth key, with WITH_TAILSCALE=true
  TS_HOSTNAME           tailnet name and T3 label, default the box name
  WITH_BROWSER          true: the headless Chromium libraries
  DEVALOY_SLIM          true: leave the large optional tools out
  UPSTASH_HOME_MODE     move (default) or links, the Home fallback

  and GITHUB_TOKEN, CLAUDE_CODE_OAUTH_TOKEN, CLOUDFLARE_API_TOKEN,
  INFISICAL_CLIENT_ID, INFISICAL_CLIENT_SECRET, DEVALOY_REPOS,
  GIT_AUTHOR_NAME, GIT_AUTHOR_EMAIL, GIT_SIGNING_SSH_KEY, NTFY_TOPIC,
  NTFY_SERVER, NTFY_TOKEN, TS_ACCEPT_DNS and MISE_NODE_VERSION.
EOF
}

ok()    { printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn()  { printf '  \033[33m!\033[0m %s\n' "$1"; }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }
die()   { printf '\n\033[31m%s\033[0m\n' "$1" >&2; exit 1; }

# --- the shared system layer ---------------------------------------------------
# put_content and friends from lib/system/, loaded from the clone, as in
# install-native.sh. Only the file helpers run as the box user here; the
# root work is the boot's.
load_system_lib() {
  [ -f "${DEVALOY_DIR}/lib/system/common.sh" ] ||
    die "${DEVALOY_DIR}/lib/system/common.sh is missing. DEVALOY_REF must name a ref that has lib/system/."
  # shellcheck source=lib/system/common.sh
  . "${DEVALOY_DIR}/lib/system/common.sh"
}

# --- /workspace/.devaloy/env ---------------------------------------------------
#
# This box's .env. The parser, the merge and the writer are in
# lib/system/envfile.sh, shared with install-native.sh; see that file for the
# grammar. The boot reads the file with the same parser, never with `source`.
# What stays here is this installer's own part: the key list, the defaults,
# the fixed values and the header.
#
# The keys are the plan's Keys row, then the four that are fixed on this
# runtime, then the two this runtime adds. UPSTASH_BOX_API_KEY is never one
# of them. A key someone added by hand is kept, after these, in its order.
ENV_KEYS=(
  TS_AUTHKEY TS_HOSTNAME TS_ACCEPT_DNS WITH_TAILSCALE
  GITHUB_TOKEN CLAUDE_CODE_OAUTH_TOKEN CLOUDFLARE_API_TOKEN
  INFISICAL_CLIENT_ID INFISICAL_CLIENT_SECRET
  DEVALOY_REPOS GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_SIGNING_SSH_KEY
  NTFY_TOPIC NTFY_SERVER NTFY_TOKEN
  WITH_BROWSER MISE_NODE_VERSION DEVALOY_REF
  WITH_T3CODE WITH_DOCKER WITH_PASEO RUNTIME
  DEVALOY_SLIM UPSTASH_HOME_MODE
)

declare -A FILE_VAL=()
FILE_ORDER=()
declare -A VAL=()

# TS_HOSTNAME has no default here: empty means the box's Upstash name, which
# the boot reads on every start, so a renamed box follows.
env_default() {
  case "$1" in
    DEVALOY_REF) printf 'main' ;;
    WITH_TAILSCALE|WITH_BROWSER) printf 'false' ;;
    DEVALOY_SLIM) printf '%s' "${DEVALOY_SLIM_DEFAULT}" ;;
    UPSTASH_HOME_MODE) printf 'move' ;;
    *) printf '' ;;
  esac
}

# The keys that are not inputs on this runtime: T3 Code is the point of the
# box, and it cannot run Docker or the Paseo daemon.
env_fixed() {
  case "$1" in
    WITH_T3CODE) printf 'true' ;;
    WITH_DOCKER|WITH_PASEO) printf 'false' ;;
    RUNTIME) printf 'upstash' ;;
    *) return 1 ;;
  esac
}

resolve_env() {
  local k
  env_merge "${ENV_FILE}"
  for k in WITH_TAILSCALE WITH_BROWSER DEVALOY_SLIM; do
    case "${VAL[${k}]}" in
      true|false) ;;
      *) die "${k}=${VAL[${k}]}: use true or false." ;;
    esac
  done
  case "${VAL[UPSTASH_HOME_MODE]}" in
    move|links) ;;
    *) die "UPSTASH_HOME_MODE=${VAL[UPSTASH_HOME_MODE]}: use move or links." ;;
  esac
}

render_env() {
  cat <<'EOF'
# devaloy's environment on this Upstash Box: the counterpart of the
# container's .env and of /etc/devaloy/env on a VM. Read on every container
# start by lib/steps/upstash-boot.sh (the Upstash init command). Written by
# scripts/install-upstash.sh. The box user only (0600).
#
# Edit a value, then run `bash /workspace/devaloy/lib/steps/upstash-boot.sh`.
# Clearing a token here and running the boot revokes it. A non-empty variable
# passed to the installer overwrites the value here; an empty one leaves it.
# WITH_T3CODE, WITH_DOCKER, WITH_PASEO and RUNTIME are fixed on this runtime.
#
# Keep the double quotes. Inside them, write \\ \" \` and \$ for a literal
# backslash, quote, backtick and dollar sign.
EOF
  env_render_keys
}

# The same loader as install-native.sh: envfile.sh from the clone, or from
# origin when the clone sits at a ref older than the file.
load_envfile_lib() {
  local lib="${DEVALOY_DIR}/lib/system/envfile.sh" tmp
  if [ -f "${lib}" ]; then
    # shellcheck source=lib/system/envfile.sh
    . "${lib}"
    return 0
  fi
  tmp="$(mktemp)"
  if git -C "${DEVALOY_DIR}" fetch --quiet origin HEAD </dev/null &&
     git -C "${DEVALOY_DIR}" show FETCH_HEAD:lib/system/envfile.sh > "${tmp}"; then
    # shellcheck source=lib/system/envfile.sh
    . "${tmp}"
    rm -f "${tmp}"
  else
    rm -f "${tmp}"
    die "Could not read lib/system/envfile.sh from ${DEVALOY_DIR} or from origin."
  fi
}

# ===============================================================================
# The steps
# ===============================================================================

inst_preflight() {
  head_ "1. Preflight"
  [ "$(id -u)" -ne 0 ] ||
    die "Run as the box user, not root: curl -fsSL ... | bash (no sudo). The boot calls sudo -n itself."
  ok "user $(id -un)"

  [ -n "${UPSTASH_BOX_ID:-}" ] ||
    die "UPSTASH_BOX_ID is not set. This installer is for an Upstash Box; on a VM use install-native.sh."
  case "${UPSTASH_BOX_RUNTIME:-node}" in
    node) ok "Upstash Box ${UPSTASH_BOX_ID} (node runtime)" ;;
    *) die "This box runs the ${UPSTASH_BOX_RUNTIME} runtime. devaloy supports the node runtime only; create the box with runtime node." ;;
  esac

  sudo -n true 2>/dev/null || die "sudo -n does not work for $(id -un). The boot needs passwordless sudo."
  ok "passwordless sudo"

  # On a real box /workspace is root:root 0711 and the box user owns only
  # /workspace/home, so the two devaloy dirs are made by root for the user.
  [ -d /workspace ] || die "/workspace is missing."
  local d
  for d in "${DEVALOY_DIR}" "${UPSTASH_DIR}"; do
    [ -d "${d}" ] || sudo -n install -d -o "$(id -un)" -g "$(id -gn)" -m 755 "${d}" ||
      die "Could not create ${d}."
    [ -w "${d}" ] || die "${d} is not writable by $(id -un)."
  done
  ok "/workspace/devaloy and /workspace/.devaloy writable"

  local id="" version=""
  if [ -r /etc/os-release ]; then
    id="$(sed -n 's/^ID=//p' /etc/os-release | tr -d '"')"
    version="$(sed -n 's/^VERSION_ID=//p' /etc/os-release | tr -d '"')"
  fi
  if [ "${id}" = debian ] && [ "${version%%.*}" -ge 12 ] 2>/dev/null; then
    ok "${id} ${version}"
  else
    die "This installer supports Debian 12 or newer only (found ${id:-unknown} ${version:-unknown})."
  fi

  case "$(uname -m)" in
    x86_64|aarch64) ok "architecture $(uname -m)" ;;
    *) die "Unsupported architecture $(uname -m). devaloy runs on x86_64 and aarch64." ;;
  esac

  timeout 10 bash -c "exec 3<>/dev/tcp/github.com/443" 2>/dev/null ||
    die "Cannot reach github.com:443. Check DNS and outbound HTTPS."
  ok "github.com reachable"

  # An Upstash Box shares its egress address with other boxes, and on the
  # first real box that address had 0 of GitHub's 60 anonymous API calls
  # left. mise resolves `latest` through that API, so the cold toolchain
  # install failed on a 403. A GITHUB_TOKEN lifts the limit to 5000. sed, not
  # jq: jq arrives with the package step, after this preflight.
  local remaining=""
  if [ -z "${GITHUB_TOKEN:-}" ] &&
     ! grep -qE '^GITHUB_TOKEN="?[^"[:space:]]' "${UPSTASH_DIR}/env" 2>/dev/null; then
    remaining="$(curl -fsS --max-time 10 https://api.github.com/rate_limit 2>/dev/null |
      tr -d ' \n' | sed -n 's/.*"core":{[^}]*"remaining":\([0-9]*\).*/\1/p' || true)"
    if [ -n "${remaining}" ] && [ "${remaining}" -lt 30 ]; then
      warn "No GITHUB_TOKEN, and this address has ${remaining} anonymous GitHub API calls left."
      warn "The toolchain install will likely fail on a 403. Set GITHUB_TOKEN to avoid it."
    fi
  fi
}

# git, curl and the trust store, for the clone. An Upstash Box has all three;
# this is for a box that does not.
pre_clone_packages() {
  local p missing=()
  for p in git ca-certificates curl; do
    dpkg-query -W -f='${db:Status-Status}' "${p}" 2>/dev/null | grep -qx installed ||
      missing+=("${p}")
  done
  [ "${#missing[@]}" -gt 0 ] || return 0
  sudo -n env DEBIAN_FRONTEND=noninteractive apt-get -q -o DPkg::Lock::Timeout=600 update </dev/null
  sudo -n env DEBIAN_FRONTEND=noninteractive \
    apt-get -q -o DPkg::Lock::Timeout=600 install -y --no-install-recommends "${missing[@]}" </dev/null
  ok "installed: ${missing[*]}"
}

# The clone belongs to the box user (the Clone owner row), so git runs as the
# user this script runs as. In two parts, as in install-native.sh: the first
# makes the clone when there is none, so the env file can be read with the
# clone's parser and DEVALOY_REF can come from it; the second moves the clone
# to that ref.
inst_clone_start() {
  head_ "2. The repo at ${DEVALOY_DIR}"
  pre_clone_packages

  if [ ! -d "${DEVALOY_DIR}/.git" ]; then
    if [ -e "${DEVALOY_DIR}" ] && [ -n "$(ls -A "${DEVALOY_DIR}" 2>/dev/null)" ]; then
      die "${DEVALOY_DIR} exists and is not a git clone. Move it aside and re-run."
    fi
    git clone --quiet "${DEVALOY_SRC:-${DEVALOY_URL}}" "${DEVALOY_DIR}" </dev/null
    ok "cloned ${DEVALOY_SRC:-${DEVALOY_URL}}"
  elif [ -n "${DEVALOY_SRC}" ] &&
       [ "$(git -C "${DEVALOY_DIR}" remote get-url origin)" != "${DEVALOY_SRC}" ]; then
    git -C "${DEVALOY_DIR}" remote set-url origin "${DEVALOY_SRC}"
  fi
}

# The fetch and checkout logic of inst_clone in install-native.sh, its twin:
# change one, change the other. It cannot be shared through lib/, because it
# runs before the clone is at the ref whose lib/ it would load.
inst_clone() {
  local ref="${VAL[DEVALOY_REF]}" remote_sha tag_sha local_sha branch
  local g=(git -C "${DEVALOY_DIR}")
  remote_sha="$("${g[@]}" ls-remote --heads origin "refs/heads/${ref}" </dev/null |
    awk -v r="refs/heads/${ref}" '$2 == r {print $1}')"
  if [ -n "${remote_sha}" ]; then
    if [ "$("${g[@]}" rev-parse -q --verify "refs/remotes/origin/${ref}" || true)" != "${remote_sha}" ]; then
      "${g[@]}" fetch --quiet origin "+refs/heads/${ref}:refs/remotes/origin/${ref}" </dev/null
    fi
    branch="$("${g[@]}" symbolic-ref -q --short HEAD || true)"
    local_sha="$("${g[@]}" rev-parse HEAD)"
    if [ "${branch}" != "${ref}" ] || [ "${local_sha}" != "${remote_sha}" ] ||
       [ "$("${g[@]}" config "branch.${ref}.merge" || true)" != "refs/heads/${ref}" ]; then
      "${g[@]}" checkout --quiet -B "${ref}" --track "origin/${ref}" </dev/null
      ok "checked out branch ${ref} at $("${g[@]}" rev-parse --short HEAD)"
    else
      ok "branch ${ref} already at $("${g[@]}" rev-parse --short HEAD)"
    fi
  else
    tag_sha="$("${g[@]}" ls-remote --tags origin "refs/tags/${ref}" </dev/null |
      awk -v r="refs/tags/${ref}" '$2 == r "^{}" {p = $1} $2 == r {t = $1} END {print (p != "" ? p : t)}')"
    [ -n "${tag_sha}" ] || die "DEVALOY_REF=${ref} is neither a branch nor a tag on origin."
    if [ "$("${g[@]}" rev-parse -q --verify "refs/tags/${ref}^{commit}" || true)" != "${tag_sha}" ]; then
      "${g[@]}" fetch --quiet --force origin "+refs/tags/${ref}:refs/tags/${ref}" </dev/null
    fi
    if "${g[@]}" symbolic-ref -q HEAD >/dev/null || [ "$("${g[@]}" rev-parse HEAD)" != "${tag_sha}" ]; then
      "${g[@]}" checkout --quiet --detach "refs/tags/${ref}" </dev/null
      ok "checked out tag ${ref} (detached; devaloy update will not pull a tag)"
    else
      ok "tag ${ref} already checked out"
    fi
  fi

  # The two flag files the boot writes into the clone's root. Excluded
  # locally so `git pull` never sees them as changes.
  local exclude="${DEVALOY_DIR}/.git/info/exclude" line
  for line in /build-flags /runtime-flags '/runtime-flags.devaloy-new'; do
    grep -qxF "${line}" "${exclude}" 2>/dev/null || {
      mkdir -p "$(dirname "${exclude}")"
      printf '%s\n' "${line}" >> "${exclude}"
    }
  done
}

# The one interactive moment of the merge: a Tailscale key, asked for only
# when Tailscale is on, there is no key, and the node has no saved state.
# The state is root's (0700), so the test goes through sudo.
# Without a terminal the boot goes on and prints the login URL instead, the
# same non-fatal path as on every runtime.
inst_env() {
  head_ "3. ${ENV_FILE}"
  if [ "${VAL[WITH_TAILSCALE]}" = true ] && [ -z "${VAL[TS_AUTHKEY]}" ] &&
     ! sudo -n test -s "${UPSTASH_DIR}/tailscale/tailscaled.state"; then
    if ( exec </dev/tty ) 2>/dev/null; then
      printf '  Tailscale auth key (tskey-auth-..., empty to skip): ' >/dev/tty
      IFS= read -r -s 'VAL[TS_AUTHKEY]' </dev/tty || true
      printf '\n' >/dev/tty
    fi
    [ -n "${VAL[TS_AUTHKEY]}" ] ||
      warn "WITH_TAILSCALE=true with no TS_AUTHKEY: the boot log will hold a login URL"
  fi

  install -d -m 700 "${UPSTASH_DIR}"
  put_content "${ENV_FILE}" 600 < <(render_env)
  if [ "${PUT_CHANGED}" -eq 1 ]; then
    ok "written ($(id -un), 0600)"
  else
    ok "unchanged"
  fi
}

# The boot streams its own log to stdout (it tees it), so running it is the
# whole wait. A Ctrl-C stops the wait and the boot with it; the next run or
# the next container start runs it again from the top.
inst_boot() {
  head_ "4. upstash-boot.sh"
  echo "  The log is ${UPSTASH_DIR}/logs/boot.log. A cold toolchain install takes"
  echo "  several minutes."
  echo
  local rc=0
  bash "${BOOT}" || rc=$?
  [ "${rc}" -eq 0 ] || die "The boot failed. Read ${UPSTASH_DIR}/logs/boot.log for the step that
broke and ${UPSTASH_DIR}/boot-status for its name. Fix it, then run
'bash ${BOOT}' or this installer again."
  ok "boot finished"
}

# --- the SDK step ----------------------------------------------------------------
#
# The box cannot set its own init command or open its own public URL from
# inside: both are calls to the Upstash API with the account's key. The key
# comes from UPSTASH_BOX_API_KEY or a silent prompt on /dev/tty. It goes to
# the one Node child below, in its environment, and nowhere else: not to the
# env file, not to an argument list, not to the terminal.
#
# The SDK goes into a temp directory and goes away with it, so nothing lands
# in /workspace. The calls are idempotent: the same init command and the same
# port give the same result on a second run.
SDK_URL=""
SDK_SCRIPT='
import { Box } from "@upstash/box";
const box = await Box.get(process.env.UPSTASH_BOX_ID);
const want = process.env.DEVALOY_BOOT_CMD;
let have = "";
try { have = await box.getInitCommand(); } catch { have = ""; }
if (have !== want) {
  await box.setInitCommand(want);
  console.log("init command set");
} else {
  console.log("init command already set");
}
const pub = await box.getPublicURL(Number(process.env.DEVALOY_T3_PORT));
console.log("url " + pub.url);
'

console_steps() {
  cat <<EOF
  Do these two steps in the Upstash console instead:

    1. Box ${UPSTASH_BOX_ID} > Init command:
         ${BOOT_CMD}
    2. Box ${UPSTASH_BOX_ID} > Public URLs: expose port ${T3CODE_PORT}.

  Or run this again with the key: install-upstash.sh --sdk-only
EOF
}

inst_sdk() {
  head_ "5. Upstash init command and public URL"
  local key="${UPSTASH_BOX_API_KEY:-}" tmp out rc=0
  if [ -z "${key}" ] && ( exec </dev/tty ) 2>/dev/null; then
    printf '  Upstash API key (empty to skip): ' >/dev/tty
    IFS= read -r -s key </dev/tty || true
    printf '\n' >/dev/tty
  fi
  if [ -z "${key}" ]; then
    warn "no UPSTASH_BOX_API_KEY and no terminal to ask on"
    console_steps
    return 0
  fi
  { command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; } ||
    die "node and npm are not on PATH; the SDK step needs them."

  tmp="$(mktemp -d)"
  if ! (cd "${tmp}" && printf '{"type":"module","private":true}\n' > package.json &&
        npm install --silent --no-audit --no-fund --no-save "${UPSTASH_BOX_SDK}" </dev/null >/dev/null 2>&1); then
    rm -rf "${tmp}"
    warn "npm install ${UPSTASH_BOX_SDK} failed"
    console_steps
    return 0
  fi
  printf '%s' "${SDK_SCRIPT}" > "${tmp}/sdk.mjs"
  out="$(cd "${tmp}" && UPSTASH_BOX_API_KEY="${key}" UPSTASH_DISABLE_TELEMETRY=1 \
    DEVALOY_BOOT_CMD="${BOOT_CMD}" DEVALOY_T3_PORT="${T3CODE_PORT}" \
    node sdk.mjs </dev/null 2>&1)" || rc=$?
  key=""
  rm -rf "${tmp}"
  if [ "${rc}" -ne 0 ]; then
    # The SDK's own error, which names the HTTP status. It never holds the key.
    printf '%s\n' "${out}" | tail -5 | sed 's/^/    /'
    warn "the SDK call failed"
    console_steps
    return 0
  fi
  printf '%s\n' "${out}" | grep -v '^url ' | while IFS= read -r line; do ok "${line}"; done
  SDK_URL="$(printf '%s\n' "${out}" | sed -n 's/^url //p' | head -1)"
  [ -z "${SDK_URL}" ] || ok "public URL ${SDK_URL}"
}

# --- the end ---------------------------------------------------------------------

# The first pairing link, through t3-pair. The server may still be starting
# when the boot returns, so wait for its listener first, bounded.
first_pair_link() {
  local home
  home="$(getent passwd "$(id -un)" | cut -d: -f6)"
  for _ in $(seq 1 60); do
    [ -n "$(ss -ltnH "sport = :${T3CODE_PORT}" 2>/dev/null)" ] && break
    sleep 1
  done
  HOME="${home}" PATH="${home}/.local/bin:/usr/local/bin:${PATH}" \
    "${home}/.local/bin/t3-pair" 2>/dev/null </dev/null || true
}

inst_done() {
  local url="${SDK_URL:-https://${UPSTASH_BOX_ID}-${T3CODE_PORT}.preview.box.upstash.com}" link
  head_ "6. Done"
  echo "  T3 Code: ${url}"
  link="$(first_pair_link | sed -n 's/^Pairing URL: //p' | head -1 || true)"
  if [ -n "${link}" ]; then
    echo "  Pair the phone with this link (one use):"
    echo "    ${link}"
  else
    warn "no pairing link yet; run t3-pair on the box once the server is up"
  fi
  cat <<EOF

  Next steps:
    - Codex: sign in once on the box with 'codex login --device-auth'.
    - Claude Code: set CLAUDE_CODE_OAUTH_TOKEN in ${ENV_FILE} (or pass it to
      this installer) and run the boot again.
    - T3 Code titles thread names with a provider; pick one in the app's
      settings once Claude or Codex is signed in.
    - A second device: run t3-pair on the box for a new link.
EOF
  echo "devaloy is up on Upstash Box ${UPSTASH_BOX_ID}."
}

main() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --cli-only) CLI_ONLY=1 ;;
      --sdk-only) SDK_ONLY=1 ;;
      --no-sdk) NO_SDK=1 ;;
      -h|--help) usage; exit 0 ;;
      *) echo "Unknown argument: $1" >&2; usage >&2; exit 1 ;;
    esac
    shift
  done
  [ $((CLI_ONLY + SDK_ONLY + NO_SDK)) -le 1 ] ||
    die "--cli-only, --sdk-only and --no-sdk do not combine; pick one."

  if [ "${CLI_ONLY}" -eq 1 ]; then
    [ -f "${DEVALOY_DIR}/devaloy" ] || die "${DEVALOY_DIR} holds no clone to install from."
    sudo -n bash -c '. "$1/lib/system/common.sh" && . "$1/lib/system/steps.sh" && sys_install_cli "$1"' \
      _ "${DEVALOY_DIR}"
    echo "devaloy: cli reinstalled from ${DEVALOY_DIR}"
    exit 0
  fi

  if [ "${SDK_ONLY}" -eq 1 ]; then
    [ -n "${UPSTASH_BOX_ID:-}" ] || die "UPSTASH_BOX_ID is not set. Run this on the Upstash Box."
    [ -f "${BOOT}" ] || die "${BOOT} is missing. Run the full installer first."
    inst_sdk
    exit 0
  fi

  inst_preflight
  inst_clone_start
  load_envfile_lib
  resolve_env
  inst_clone
  load_system_lib
  inst_env
  inst_boot
  if [ "${NO_SDK}" -eq 1 ]; then
    head_ "5. Upstash init command and public URL"
    ok "skipped (--no-sdk)"
  else
    inst_sdk
  fi
  inst_done
}

# main is called on the last line on purpose. Under `curl | bash`, bash reads
# the script from stdin as it goes; by the time main runs, bash has read every
# function above it, so a command inside that reads stdin cannot swallow the
# rest of the script.
main "$@"
