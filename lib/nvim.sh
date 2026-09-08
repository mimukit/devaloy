#!/usr/bin/env bash
# devaloy: re-copy the repo's LazyVim config over ~/.config/nvim.
#
# The boot-time seed in bootstrap-toolchain.sh is guarded on the directory, so
# it fires once and never again — that is what keeps your own edits on the box
# safe across a redeploy. This is the deliberate way to pull the repo copy back
# over the top: after changing config/nvim/ in the devaloy repo, or on a box
# seeded before config/nvim/ existed and still holding upstream's starter.
#
# It backs up first, because the whole point of the seed guard is that the
# directory it overwrites may hold work only this box has.
#
# Usage: devaloy nvim-sync [--no-backup]

NVIM_CONFIG_SRC="/opt/devaloy/config/nvim"
NVIM_CONFIG_DEST="${HOME}/.config/nvim"
NVIM_BACKUP=1

nvim_args() {
  local arg
  for arg in "$@"; do
    case "${arg}" in
      --no-backup) NVIM_BACKUP=0 ;;
      -h | --help)
        echo "usage: devaloy nvim-sync [--no-backup]"
        echo
        echo "Copies ${NVIM_CONFIG_SRC} over ${NVIM_CONFIG_DEST}, then runs a"
        echo "headless Lazy sync. Backs the current directory up first unless"
        echo "--no-backup is given."
        exit 0
        ;;
      *) die "nvim-sync: unknown argument '${arg}'." ;;
    esac
  done
}

do_nvim_sync() {
  nvim_args "$@"

  # Same check as update: root would write the files with the wrong owner and
  # leave the dev user unable to edit its own editor config.
  refuse_root nvim-sync

  if [ ! -d "${NVIM_CONFIG_SRC}" ]; then
    echo "devaloy nvim-sync: ${NVIM_CONFIG_SRC} is missing." >&2
    die "this image predates config/nvim/. Rebuild with a newer devaloy."
  fi

  if [ -d "${NVIM_CONFIG_DEST}" ] && [ "${NVIM_BACKUP}" -eq 1 ]; then
    # Second-resolution stamp, so two runs a minute apart do not collide.
    local backup_dir
    backup_dir="${NVIM_CONFIG_DEST}.bak-$(date +%Y%m%d-%H%M%S)"
    mv "${NVIM_CONFIG_DEST}" "${backup_dir}"
    echo "devaloy nvim-sync: previous config moved to ${backup_dir}"
  elif [ -d "${NVIM_CONFIG_DEST}" ]; then
    # --no-backup deletes rather than merges. A merge would leave behind any
    # file you have since removed from config/nvim/, which is not a sync.
    rm -rf "${NVIM_CONFIG_DEST}"
  fi

  # The trailing /. copies the contents, dotfiles included — .neoconf.json and
  # .gitignore are both part of the config.
  mkdir -p "${NVIM_CONFIG_DEST}"
  cp -R "${NVIM_CONFIG_SRC}/." "${NVIM_CONFIG_DEST}/"
  echo "devaloy nvim-sync: config copied from ${NVIM_CONFIG_SRC}"

  # Resolve the plugin set now rather than on the next `nvim`, matching what the
  # boot-time seed does. Non-fatal: a failed sync leaves a working config that
  # retries on the next start.
  if ! nvim --headless "+Lazy! sync" +qa 2>&1 | tail -5; then
    echo "WARNING: the Lazy sync failed — run it again inside nvim." >&2
  fi

  echo "devaloy: nvim config synced."
}
