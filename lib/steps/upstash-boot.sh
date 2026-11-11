#!/usr/bin/env bash
# devaloy on an Upstash Box: the per-start work, run by the Upstash init
# command and by scripts/install-upstash.sh.
#
# The Upstash twin of native-boot.sh. An Upstash Box has no systemd, and a
# pause kills every process but keeps the filesystem. A reset wipes all of it,
# /workspace included (Phase 7, box needed-tortoise-40254); only the init
# command and the public URL survive, so after a reset the init command finds
# no clone and the one-liner is the way back. The init command runs once per container start (create, resume,
# snapshot restore), so this one script is the boot unit and the supervisor
# both. In order:
#
#   1. converge the overlay: what lives outside /workspace, which a new
#      container from a snapshot may not carry. The /opt/devaloy link to the clone, the box user's home and shell,
#      the apt packages, zsh-completions, the devaloy CLI and build-flags.
#      Every piece checks before it writes, so on a resume this costs a few
#      dpkg queries and no download.
#   2. the same lib/steps/ calls as native_boot, minus Docker and Paseo, which
#      this runtime does not have
#   3. t3-pair in ~/.local/bin, and /workspace/.devaloy/boot-status for
#      `devaloy doctor`
#   4. start the T3 Code serve loop (and tailscaled, before the steps that
#      need it) through upstash-serve.sh, detached
#
# Two modes:
#
#   upstash-boot.sh             the boot, in the foreground. The installer runs
#                               this, and so can a human after a change to
#                               /workspace/.devaloy/env. Output goes to the
#                               terminal and to the log.
#   upstash-boot.sh --detach    start the same boot with setsid and exit 0 at
#                               once. This is the Upstash init command, so it
#                               does not matter whether Upstash waits on it or
#                               gives it a timeout.
#
# The log is /workspace/.devaloy/logs/boot.log; the one from the boot before
# is boot.log.1. Runs as the box user and re-runs itself as root with
# `sudo -n`. Lives on /workspace, not in /usr/local/lib/devaloy, because the
# init command must find it in a container whose overlay is new.
set -euo pipefail

# Files the boot writes must be readable by the box user, and a `docker exec`
# or an init command may hand over a looser or tighter umask than a login.
umask 022

DEVALOY_DIR=/workspace/devaloy
UPSTASH_DIR=/workspace/.devaloy
UPSTASH_ENV_FILE="${UPSTASH_DIR}/env"
BOOT_LOG="${UPSTASH_DIR}/logs/boot.log"
BOOT_STATUS="${UPSTASH_DIR}/boot-status"
BOOT_LOCK="${UPSTASH_DIR}/run/boot.lock"
WORKSPACE_HOME=/workspace/home
BOX_USER="${BOX_USER:-boxuser}"
SELF="$(readlink -f "${BASH_SOURCE[0]}")"

# The ports and the Home fallback list from the plan. native-serve.sh and
# upstash-serve.sh carry the same port.
T3CODE_PORT=3773
HOME_LINKS=(.config .local/bin .gitconfig .claude.json .zshrc .zshenv .t3 projects
  worktrees .devaloy_env .devaloy_secrets)

# The boot before this one, kept as boot.log.1. Called by the process that
# opens the log, before it opens it.
rotate_log() {
  mkdir -p "$(dirname "${BOOT_LOG}")"
  if [ -s "${BOOT_LOG}" ]; then
    mv -f "${BOOT_LOG}" "${BOOT_LOG}.1"
  fi
}

# --- --detach: the Upstash init command ----------------------------------------
if [ "${1:-}" = "--detach" ]; then
  rotate_log
  UPSTASH_BOOT_DETACHED=1 setsid nohup bash "${SELF}" >> "${BOOT_LOG}" 2>&1 < /dev/null &
  echo "devaloy: boot started in the background, log in ${BOOT_LOG}"
  exit 0
fi
[ $# -eq 0 ] || { echo "upstash-boot.sh: unknown argument '$1' (expected --detach or none)" >&2; exit 2; }

# --- root ------------------------------------------------------------------------
# sudo resets the environment, so the few variables the boot reads from it go
# across on the command line. None of them is a secret: every secret comes
# from the env file below, which root reads itself.
if [ "$(id -u)" -ne 0 ]; then
  exec sudo -n env \
    UPSTASH_BOX_ID="${UPSTASH_BOX_ID:-}" \
    UPSTASH_BOX_NAME="${UPSTASH_BOX_NAME:-}" \
    UPSTASH_BOOT_DETACHED="${UPSTASH_BOOT_DETACHED:-0}" \
    LANG="${LANG:-}" \
    bash "${SELF}"
fi

# In the foreground the output goes to the terminal and to the log; detached,
# the --detach branch already pointed it at the log. tee runs as a process
# substitution, and the EXIT trap waits for it, so its last lines reach the
# terminal before the script ends.
TEE_PID=""
if [ "${UPSTASH_BOOT_DETACHED:-0}" != 1 ]; then
  rotate_log
  exec > >(tee -a "${BOOT_LOG}") 2>&1
  TEE_PID=$!
fi

# One boot at a time. The init command and a hand-run boot can overlap after
# a resume; the second waits for the first, then finds everything converged.
# Opened for append, so taking the lock does not touch the file's mtime.
mkdir -p "$(dirname "${BOOT_LOCK}")"
exec 9>> "${BOOT_LOCK}"
flock -w 1800 9 || { echo "[devaloy] another boot holds ${BOOT_LOCK}; giving up." >&2; exit 1; }

# --- boot-status -------------------------------------------------------------------
# `ok <time>` or `failed <step> <time>`, for `devaloy doctor`. The EXIT trap
# writes it whatever ends the script, so a step that dies under set -e still
# leaves the name of the step behind. A step that fails softly (the toolchain)
# sets FAILED_STEP and the boot goes on, then exits 1 at the end.
CURRENT_STEP=start
FAILED_STEP=""
boot_exit() {
  local rc=$? stamp
  stamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if [ "${rc}" -eq 0 ]; then
    printf 'ok %s\n' "${stamp}" > "${BOOT_STATUS}"
  else
    printf 'failed %s %s\n' "${FAILED_STEP:-${CURRENT_STEP}}" "${stamp}" > "${BOOT_STATUS}"
    echo "[devaloy] the boot failed at step ${FAILED_STEP:-${CURRENT_STEP}} (exit ${rc})."
  fi
  chown -R "${BOX_USER}:${BOX_USER}" "${UPSTASH_DIR}/logs" "${BOOT_STATUS}" 2>/dev/null || true
  if [ -n "${TEE_PID}" ]; then
    exec >&- 2>&-
    wait "${TEE_PID}" 2>/dev/null || true
  fi
}
trap boot_exit EXIT
step() { CURRENT_STEP="$1"; }

# --- the inputs ------------------------------------------------------------------
# /workspace/.devaloy/env, read with the installers' parser and never with
# `source`: a token can hold a `$` or a backtick. Every key in it is exported,
# as systemd's EnvironmentFile= exports every key on a VM. The four keys after
# it are not inputs on this runtime, whatever the file says.
step env
[ -f "${DEVALOY_DIR}/lib/system/envfile.sh" ] ||
  { echo "[devaloy] ${DEVALOY_DIR} holds no devaloy clone. Run scripts/install-upstash.sh." >&2; exit 1; }
# shellcheck source=lib/system/envfile.sh
. "${DEVALOY_DIR}/lib/system/envfile.sh"
read_env_file "${UPSTASH_ENV_FILE}"
for _k in "${FILE_ORDER[@]}"; do
  export "${_k}=${FILE_VAL[${_k}]}"
done
unset _k
export RUNTIME=upstash WITH_T3CODE=true WITH_DOCKER=false WITH_PASEO=false
# Tailscale is on by default on this runtime (plan 0016 Part 2): ssh, fleet
# and wtforward reach every devaloy box the same way. WITH_TAILSCALE="false"
# in the env file turns it off.
export WITH_TAILSCALE="${WITH_TAILSCALE:-true}" WITH_BROWSER="${WITH_BROWSER:-false}"

# The box ID and name are in the container's environment, which is PID 1's.
# The init command may not hand them on, so read them from there when sudo
# brought none.
pid1_env() { tr '\0' '\n' < /proc/1/environ 2>/dev/null | sed -n "s/^$1=//p" | head -1; }
UPSTASH_BOX_ID="${UPSTASH_BOX_ID:-$(pid1_env UPSTASH_BOX_ID)}"
UPSTASH_BOX_NAME="${UPSTASH_BOX_NAME:-$(pid1_env UPSTASH_BOX_NAME)}"
export UPSTASH_BOX_ID UPSTASH_BOX_NAME

# The tailnet name and the T3 environment label: TS_HOSTNAME when the file
# sets it, else the box's Upstash name.
export TS_HOSTNAME="${TS_HOSTNAME:-${UPSTASH_BOX_NAME:-devaloy}}"
# tailscaled's state sits on /workspace, so the node keeps its identity
# through a pause and a snapshot restore. upstash-serve.sh starts it with the same directory.
export TS_STATE_DIR="${UPSTASH_DIR}/tailscale"

# Tailscale on, but nothing to log in with: no TS_AUTHKEY and no node that
# logged in before. On other runtimes `tailscale up` then prints a login URL
# into the log, but here the boot mostly runs detached from the init command,
# where nobody reads the log. So the boot leaves Tailscale off for this start
# and says why, and the env file keeps WITH_TAILSCALE as it is: the first
# start that finds a key turns it on. The installer applies the same test
# before it asks for a key, and so learns nothing from the boot.
#
# A node that logged in has a profile in its state file. tailscaled writes
# the file (with only a machine key) as soon as it starts, so a non-empty
# file alone would count a node whose `up` failed as logged in.
ts_node_known() {
  grep -qs '"_current-profile"' "${TS_STATE_DIR}/tailscaled.state"
}
TAILSCALE_NO_KEY=0
if [ "${WITH_TAILSCALE}" = true ] && [ -z "${TS_AUTHKEY:-}" ] && ! ts_node_known; then
  TAILSCALE_NO_KEY=1
  WITH_TAILSCALE=false
fi

# The home. `move` (the default) sets the box user's passwd home to
# /workspace/home, so every dotfile lands on the persistent disk with no
# link list. `links` is the Home fallback from the plan: the passwd home stays
# /home/boxuser, and a fixed list of names in it links into /workspace/home.
UPSTASH_HOME_MODE="${UPSTASH_HOME_MODE:-move}"
case "${UPSTASH_HOME_MODE}" in
  move) export DEV_HOME="${WORKSPACE_HOME}" ;;
  links) export DEV_HOME="/home/${BOX_USER}" ;;
  *) echo "[devaloy] UPSTASH_HOME_MODE=${UPSTASH_HOME_MODE}: use move or links." >&2; exit 1 ;;
esac
export DEV_USER="${BOX_USER}"

DEVALOY_LIB="${DEVALOY_DIR}/lib"
# shellcheck source=lib/system/common.sh
. "${DEVALOY_LIB}/system/common.sh"
# shellcheck source=lib/system/steps.sh
. "${DEVALOY_LIB}/system/steps.sh"
# shellcheck source=lib/steps/common.sh
. "${DEVALOY_LIB}/steps/common.sh"
# shellcheck source=lib/steps/env.sh
. "${DEVALOY_LIB}/steps/env.sh"
# shellcheck source=lib/steps/tailscale.sh
. "${DEVALOY_LIB}/steps/tailscale.sh"
# shellcheck source=lib/steps/toolchain.sh
. "${DEVALOY_LIB}/steps/toolchain.sh"
# shellcheck source=lib/steps/git.sh
. "${DEVALOY_LIB}/steps/git.sh"
# shellcheck source=lib/steps/t3code.sh
. "${DEVALOY_LIB}/steps/t3code.sh"

SERVE=(bash "${DEVALOY_LIB}/steps/upstash-serve.sh")

# --- 1. the overlay --------------------------------------------------------------

# user_dir DIR — mkdir -p, with every directory it makes owned by the box
# user. `install -d -o` gives the owner to the last one only, and a root-owned
# ~/.local stops every later step that writes there as the box user.
user_dir() {
  local d="$1" missing=()
  while [ ! -d "${d}" ]; do
    missing=("${d}" "${missing[@]}")
    d="$(dirname "${d}")"
  done
  for d in "${missing[@]}"; do
    install -d -o "${BOX_USER}" -g "${BOX_USER}" "${d}"
  done
}

# Every hardcoded /opt/devaloy path (CONFIG_SRC, build-flags, runtime-flags,
# config_src() in bootstrap-toolchain.sh) resolves through this link to the
# clone on /workspace, so none of them needs an Upstash branch.
overlay_opt_link() {
  if [ "$(readlink /opt/devaloy 2>/dev/null)" = "${DEVALOY_DIR}" ]; then
    return 0
  fi
  if [ -e /opt/devaloy ] && [ ! -L /opt/devaloy ]; then
    sys_die "/opt/devaloy exists and is not a link. Move it aside and run the boot again."
  fi
  mkdir -p /opt
  ln -sfn "${DEVALOY_DIR}" /opt/devaloy
  sys_ok "/opt/devaloy -> ${DEVALOY_DIR}"
}

# The same package steps as the image and the native installer. Tailscale can
# be off here, so its repo and package come only with WITH_TAILSCALE=true.
overlay_apt() {
  if [ "${WITH_TAILSCALE}" = true ]; then
    sys_tailscale_repo
    sys_base_packages "${DEVALOY_DIR}"
  else
    sys_base_packages "${DEVALOY_DIR}" tailscale
  fi
  sys_zsh_completions
  if [ "${WITH_BROWSER}" = true ]; then
    sys_browser_packages "${DEVALOY_DIR}"
  fi
}

# The passwd entry. usermod -d without -m only rewrites the entry: nothing
# moves, and /home/boxuser keeps its Upstash links. /etc/passwd is on the
# overlay, so a new container has the old entry and this runs again.
overlay_user() {
  local home shell want_home d
  user_dir "${WORKSPACE_HOME}"
  # The directories Upstash makes for its own links into /workspace/home. A
  # root-owned ~/.local would stop every step that writes under it as the
  # box user, so the box user owns them (the directory, not what is in it).
  for d in "${WORKSPACE_HOME}" "${WORKSPACE_HOME}/.local" "${WORKSPACE_HOME}/.local/share"; do
    if [ -d "${d}" ] && [ "$(stat -c %U "${d}")" != "${BOX_USER}" ]; then
      chown "${BOX_USER}:${BOX_USER}" "${d}"
    fi
  done
  want_home="${DEV_HOME}"
  home="$(getent passwd "${BOX_USER}" | cut -d: -f6)"
  shell="$(getent passwd "${BOX_USER}" | cut -d: -f7)"
  if [ "${home}" != "${want_home}" ]; then
    usermod -d "${want_home}" "${BOX_USER}"
    sys_ok "${BOX_USER}: home ${want_home}"
  else
    sys_ok "${BOX_USER}: home ${want_home} already"
  fi
  if [ "${shell}" != /usr/bin/zsh ]; then
    usermod -s /usr/bin/zsh "${BOX_USER}"
    sys_ok "${BOX_USER}: shell /usr/bin/zsh"
  fi

  # Upstash SSH runs a remote command (`ssh <box> cmd`) through `bash -lc`,
  # which reads ~/.profile and nothing else. /workspace/home starts with none,
  # so such a command found the runner's old claude, not the mise one. The
  # stock .profile sources .bashrc, and step_shell_hooks hooks .devaloy_env
  # into .bashrc. Copied once; an edited .profile stays as it is.
  if [ ! -e "${DEV_HOME}/.profile" ] && [ -f /etc/skel/.profile ]; then
    install -m 644 -o "${BOX_USER}" -g "${BOX_USER}" /etc/skel/.profile "${DEV_HOME}/.profile"
    sys_ok "${BOX_USER}: ~/.profile from /etc/skel"
  fi

  # The Fleet row: a second name for the same uid, so `ssh dev@<name>` and
  # `devaloy fleet` work over Tailscale SSH with no change to lib/fleet.sh.
  # Only with Tailscale: without it nothing reaches the box by that name.
  if [ "${WITH_TAILSCALE}" = true ] && ! getent passwd dev >/dev/null 2>&1; then
    useradd -o -M -u "$(id -u "${BOX_USER}")" -g "$(id -g "${BOX_USER}")" \
      -d "${WORKSPACE_HOME}" -s /usr/bin/zsh dev
    sys_ok "dev: a second name for uid $(id -u "${BOX_USER}")"
  fi
}

# The Home fallback (UPSTASH_HOME_MODE=links). Each name in HOME_LINKS becomes
# a link from /home/boxuser into /workspace/home. A real file or directory
# found there moves to /workspace/home first when nothing is there yet; when
# both exist, both stay and the boot warns, because picking one would lose
# the other. The names that are directories get their target made, so a link
# never dangles where a step would create a file under it. So do the files a
# step copies or merges into (`cp` refuses to write through a dangling link):
# empty, or `{}` for ~/.claude.json. The two devaloy files are left to
# commit_staged, which writes through a link and removes the target to revoke.
overlay_home_links() {
  local name src dst
  [ "${UPSTASH_HOME_MODE}" = links ] || return 0
  for name in "${HOME_LINKS[@]}"; do
    src="${DEV_HOME}/${name}"
    dst="${WORKSPACE_HOME}/${name}"
    if [ "$(readlink "${src}" 2>/dev/null)" != "${dst}" ]; then
      if [ -e "${src}" ] && [ ! -L "${src}" ]; then
        if [ -e "${dst}" ]; then
          sys_warn "${src} and ${dst} both exist; left as they are"
          continue
        fi
        user_dir "$(dirname "${dst}")"
        mv "${src}" "${dst}"
      fi
      user_dir "$(dirname "${src}")"
      ln -sfn "${dst}" "${src}"
      chown -h "${BOX_USER}:${BOX_USER}" "${src}"
    fi
    case "${name}" in
      .config|.local/bin|.t3|projects|worktrees) user_dir "${dst}" ;;
      .gitconfig|.zshrc|.zshenv|.claude.json)
        [ -e "${dst}" ] || {
          if [ "${name}" = .claude.json ]; then echo '{}'; fi > "${dst}"
          chown "${BOX_USER}:${BOX_USER}" "${dst}"
        } ;;
    esac
  done
  sys_ok "home links: ${DEV_HOME} -> ${WORKSPACE_HOME}"
}

# The flag files sit in the clone's root, where every runtime keeps them.
# install-upstash.sh adds both to the clone's .git/info/exclude.
overlay_cli() {
  sys_install_cli "${DEVALOY_DIR}"
  sys_build_flags "${DEVALOY_DIR}" upstash false "${WITH_BROWSER}"
}

# --- 3. t3-pair ------------------------------------------------------------------
# `t3 pair` prints its links with the container's own address, which reaches
# nothing from a phone. The phone reaches the server through the Upstash
# preview URL, so this wrapper swaps the scheme, host and port of every link
# for that URL, the plain ones and the URL-encoded one inside the t3code://
# app link. The QR code is dropped: it encodes the container address, and
# t3 has no flag to give it another one. The box ID is written in as a
# fallback, for a shell whose environment does not carry UPSTASH_BOX_ID. Only
# this runtime needs it, so the boot writes it, not config/bin/.
write_t3_pair() {
  local dest="${DEV_HOME}/.local/bin/t3-pair"
  user_dir "${DEV_HOME}/.local/bin"
  put_content "${dest}" 755 < <(sed "s/@BOX_ID@/${UPSTASH_BOX_ID}/" <<'EOF'
#!/usr/bin/env bash
# Print a T3 Code pairing link that works from a phone. Written by
# lib/steps/upstash-boot.sh on every boot; edits here do not last.
#
# Runs `t3 pair "$@"` and rewrites the host of every link it prints to this
# box's Upstash preview URL for port 3773. The QR code is left out, because
# it holds the container address.
set -euo pipefail
box_id="${UPSTASH_BOX_ID:-@BOX_ID@}"
[ -n "${box_id}" ] || { echo "t3-pair: UPSTASH_BOX_ID is not set." >&2; exit 1; }
url="https://${box_id}-3773.preview.box.upstash.com"
t3 pair "$@" | LC_ALL=C sed -E \
  -e '/^[[:space:]█▀▄]+$/d' \
  -e "s#https?://[^/[:space:])]+#${url}#g" \
  -e "s#https?%3A%2F%2F[^%/[:space:])]+(%3A[0-9]+)?#${url/:\/\//%3A%2F%2F}#g"
EOF
  )
  chown "${BOX_USER}:${BOX_USER}" "${dest}"
}

# --- the boot ----------------------------------------------------------------------

upstash_boot() {
  log "devaloy boot on Upstash Box ${UPSTASH_BOX_NAME:-?} (${UPSTASH_BOX_ID:-no id})"

  step overlay
  overlay_opt_link
  overlay_apt
  overlay_user
  overlay_home_links
  overlay_cli

  # --- the dev shell, secrets and dotfiles ---
  step dotfiles
  step_shell_env
  step_browser_env
  step_shell_hooks
  step_retire_banner
  step_secrets
  step_push_config
  step_seed_config
  step_claude_onboarding

  # --- Tailscale SSH (WITH_TAILSCALE=true) ---
  # Before the toolchain, as in the container, so the box is reachable over
  # the tailnet while a cold install runs. Non-fatal, as on every runtime.
  # With the key off, a tailscaled an earlier boot started is stopped, as the
  # native installer stops a unit whose key went off.
  if [ "${WITH_TAILSCALE}" != true ]; then
    "${SERVE[@]}" tailscaled stop 9>&- >/dev/null
    if [ "${TAILSCALE_NO_KEY}" = 1 ]; then
      log "WARNING: Tailscale is on, but there is no TS_AUTHKEY and the node never"
      log "WARNING: logged in, so it stays off on this start. Set TS_AUTHKEY in"
      log "WARNING: ${UPSTASH_ENV_FILE}, then run '${UPSTASH_BOOT_CMD}'."
    fi
  else
    step tailscale
    # 9>&- here and below: the loops outlive the boot, and must not hold
    # the boot lock open for the next one.
    if "${SERVE[@]}" tailscaled start 9>&-; then
      step_tailscale_ensure
    else
      log "WARNING: tailscaled did not start; the box is not on the tailnet."
    fi
  fi

  # --- mise bootstrap + pinned toolchain (runs as the box user) ---
  step toolchain
  step_browser_libs_check
  step_runtime_flags
  step_toolchain
  if [ "${TOOLCHAIN_OK:-0}" != 1 ]; then
    FAILED_STEP=toolchain
  fi
  step_t3code_upgrade
  step_link_shims

  # --- git: gh auth, identity, signing, clones ---
  step git
  step_gh_auth
  step_git_identity
  step_signing
  step_clone_repos

  # --- T3 Code ---
  # The label is read when the server starts, so it goes first. The serve
  # loop is a no-op when one already runs, so a resume that finds the old
  # loop gone starts a new one, and a second boot leaves the running one.
  step t3code
  step_t3code_config
  step_t3code_label
  step_t3code_projects
  write_t3_pair
  if "${SERVE[@]}" t3 start 9>&-; then
    log "T3 Code server on :${T3CODE_PORT}, reached at"
    log "  https://${UPSTASH_BOX_ID:-<box-id>}-${T3CODE_PORT}.preview.box.upstash.com"
    log "Pair a device with the link from: t3-pair"
  else
    FAILED_STEP="${FAILED_STEP:-t3code}"
  fi

  if [ -n "${FAILED_STEP}" ]; then
    if [ "${FAILED_STEP}" = toolchain ]; then
      log "WARNING: the boot failed because the toolchain bootstrap failed."
      log "WARNING: run 'devaloy update', then '${UPSTASH_BOOT_CMD}'."
    fi
    return 1
  fi
  step finished
  log "devaloy is up."
}

upstash_boot
