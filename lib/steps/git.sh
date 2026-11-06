#!/usr/bin/env bash
# devaloy boot steps: gh auth, git identity, commit signing and repo clones.
#
# Sourced by entrypoint.sh after common.sh, never executed. The four steps run
# in the order they appear here, and each one leans on the one before it: the
# identity fallback shells out to the gh login, signing reads GIT_EMAIL from
# the identity step, and the clones use the credential helper gh installs.

# --- gh and git over HTTPS via GITHUB_TOKEN ---
# Run after link-shims because that is what puts gh on root's PATH.
#
# gh's credential is stored on disk rather than left to the environment, and
# that is the whole point of this block. gh does read GITHUB_TOKEN by itself,
# but only from a process that HAS it — and the token deliberately lives in
# ~/.devaloy_secrets (see step_secrets), which nothing sources except
# .zshenv and .bashrc. The Paseo daemon and the T3 Code server are started
# through `su -l -s /bin/sh`, which reads neither and which clears the
# environment it inherited from PID 1, so every `gh` such a server shells out
# for would come back with "To get started with GitHub CLI, please run: gh auth
# login" while an interactive terminal on the same box worked fine. Storing it takes the environment out of the loop for
# every consumer at once, instead of teaching each one to source the file.
#
# hosts.yml is rebuilt from scratch on every boot, exactly like
# ~/.devaloy_secrets — removed whenever it does not hold exactly the current
# GITHUB_TOKEN, and always when the token is empty, so clearing GITHUB_TOKEN
# in .env and redeploying genuinely revokes gh's access rather than leaving a
# working credential behind in the home volume.
#
# A hosts.yml that already holds the current token is the one exception, and
# it is kept as it is. Logging in again would write the same credential back
# and rewrite the file, and a native re-run must leave an unchanged home alone
# (see commit_staged in common.sh). The comparison runs inside the dev shell,
# so the token never reaches an argument list.
step_gh_auth() {
  if [ -n "${GITHUB_TOKEN:-}" ] && [ -x /usr/local/bin/gh ]; then
    # shellcheck disable=SC2016  # $HOME and $GITHUB_TOKEN belong to the dev shell.
    if as_dev '. "$HOME/.devaloy_secrets"; _t="$GITHUB_TOKEN"; unset GITHUB_TOKEN GH_TOKEN
        [ -f "$HOME/.config/gh/hosts.yml" ] && [ "$(gh auth token 2>/dev/null)" = "$_t" ]' 2>/dev/null; then
      log "gh authenticated to GitHub (credential stored, not environment-bound)"
    else
      rm -f "${DEV_HOME}/.config/gh/hosts.yml"
      # The token is read from the 0600 file and piped on stdin, never passed as an
      # argument, where it would be readable in /proc for the life of the call.
      # GITHUB_TOKEN has to be unset around the call itself: gh refuses to write
      # hosts.yml while an environment token is set, on the grounds that the
      # environment would outrank the stored credential anyway.
      # shellcheck disable=SC2016  # $HOME and $GITHUB_TOKEN belong to the dev shell.
      if as_dev '. "$HOME/.devaloy_secrets"; _t="$GITHUB_TOKEN"; unset GITHUB_TOKEN GH_TOKEN; printf "%s" "$_t" | gh auth login --with-token' 2>/dev/null; then
        log "gh authenticated to GitHub (credential stored, not environment-bound)"
      else
        log "WARNING: gh auth login failed — any gh call from outside a login shell,"
        log "WARNING: such as one the Paseo daemon or T3 Code server makes, will"
        log "WARNING: report that you must run 'gh auth login' first."
      fi
    fi

    # Already in the end state that the setup-git call and the repoint below
    # produce: at least one gh helper, and every gh helper on
    # /usr/local/bin/gh. Running both again would rewrite ~/.gitconfig to the
    # same bytes, so a re-run skips them. GH_HELPERS_OK is 1 in that case.
    # shellcheck disable=SC2016  # the pipeline belongs to the dev user's shell.
    if as_dev 'h="$(git config --global --get-regexp "^credential\..*\.helper$" 2>/dev/null |
        grep "gh auth git-credential")"
      [ -n "$h" ] && ! printf "%s\n" "$h" | grep -qv " !/usr/local/bin/gh auth git-credential$"' 2>/dev/null; then
      GH_HELPERS_OK=1
    else
      GH_HELPERS_OK=0
    fi

    # Teaches git to ask gh for credentials, so `git push` works without a second
    # login. The helper it installs re-invokes gh, which is why this runs after
    # the login above — with hosts.yml in place the helper answers from any
    # process, including one a remote runtime spawned, rather than only from a
    # login shell.
    # Still sources the secrets itself so that a failed login above costs the
    # pickers but not `git push`, which the environment token alone can carry.
    # shellcheck disable=SC2016  # $HOME is expanded by the dev user's shell.
    if [ "${GH_HELPERS_OK}" = 1 ] ||
       as_dev '. "$HOME/.devaloy_secrets" && gh auth setup-git' 2>/dev/null; then
      log "git configured to authenticate to GitHub through gh"
    else
      log "WARNING: gh auth setup-git failed — 'git push' over HTTPS may prompt."
    fi

    # `gh auth setup-git` writes the helper as the ABSOLUTE path of the gh binary
    # it ran as, which resolves through the shim to
    # ~/.local/share/mise/installs/gh/<version>/... — a path that stops existing
    # the moment `devaloy update` moves gh and `mise prune` drops the old version.
    # git then dies on "gh: not found" and asks for a username instead, and the
    # box cannot push until the next redeploy rewrites this.
    #
    # Rewrite it to /usr/local/bin/gh, the link-shims mirror of the shim, which
    # carries no version in its name and resolves the current one at exec time.
    # Only entries that already hold a gh helper are touched — the empty `helper =`
    # line setup-git writes first is a deliberate reset of any inherited helper and
    # has to survive. lib/update.sh repairs the same keys after a gh upgrade.
    # shellcheck disable=SC2016  # the pipeline belongs to the dev user's shell.
    [ "${GH_HELPERS_OK}" = 1 ] ||
    as_dev 'git config --global --get-regexp "^credential\..*\.helper$" 2>/dev/null |
      awk "/gh auth git-credential/ {print \$1}" | sort -u |
      while read -r key; do
        git config --global --replace-all "$key" \
          "!/usr/local/bin/gh auth git-credential" "git-credential"
      done' 2>/dev/null || \
      log "WARNING: could not repoint gh's git credential helper at /usr/local/bin."
  else
    rm -f "${DEV_HOME}/.config/gh/hosts.yml"
  fi
}

# --- git identity ---
# Without this every commit from the box dies with "Author identity unknown",
# which an unattended agent cannot recover from. Written with `git config
# --global`, one key at a time, rather than by templating ~/.gitconfig: the file
# lives in the home volume and may hold aliases, diff tools and other settings
# added by hand, and only the keys below are ours to own.
#
# Runs after the gh block on purpose — the fallback path shells out to gh.
#
# Sets GIT_NAME and GIT_EMAIL as globals; step_signing reads GIT_EMAIL.
step_git_identity() {
  GIT_NAME="${GIT_AUTHOR_NAME:-}"
  GIT_EMAIL="${GIT_AUTHOR_EMAIL:-}"

  # Fallback: ask GitHub who the token belongs to. The address is the account's
  # ID+login noreply form rather than .email, because .email is null unless the
  # profile email is public, and the noreply address is ALWAYS a verified address
  # on the account — which is what GitHub requires before it will mark a signed
  # commit as Verified.
  if { [ -z "${GIT_NAME}" ] || [ -z "${GIT_EMAIL}" ]; } &&
     [ -n "${GITHUB_TOKEN:-}" ] && [ -x /usr/local/bin/gh ]; then
    # shellcheck disable=SC2016  # $HOME is expanded by the dev user's shell.
    GH_USER_JSON="$(as_dev '. "$HOME/.devaloy_secrets" && gh api user' 2>/dev/null || true)"
    if [ -n "${GH_USER_JSON}" ]; then
      # `|| true` inside each substitution, not after: gh can hand back a body
      # that is not the object jq expects, and a bare jq failure would take the
      # whole entrypoint down under `set -e` before tailscaled is even waited on.
      [ -n "${GIT_NAME}" ] || GIT_NAME="$(printf '%s' "${GH_USER_JSON}" |
        jq -r '.name // .login // empty' 2>/dev/null || true)"
      [ -n "${GIT_EMAIL}" ] || GIT_EMAIL="$(printf '%s' "${GH_USER_JSON}" |
        jq -r 'select(.id and .login) | "\(.id)+\(.login)@users.noreply.github.com"' 2>/dev/null || true)"
    fi
  fi

  if [ -n "${GIT_NAME}" ] && [ -n "${GIT_EMAIL}" ]; then
    git_cfg user.name  "${GIT_NAME}"
    git_cfg user.email "${GIT_EMAIL}"
    log "git identity set to ${GIT_NAME} <${GIT_EMAIL}>"
  else
    log "WARNING: no git identity — commits from this box will fail with"
    log "WARNING: 'Author identity unknown'. Set GIT_AUTHOR_NAME and"
    if on_native; then
      log "WARNING: GIT_AUTHOR_EMAIL in /etc/devaloy/env, or supply a GITHUB_TOKEN."
    else
      log "WARNING: GIT_AUTHOR_EMAIL in .env, or supply a GITHUB_TOKEN."
    fi
  fi
}

# --- SSH-signed commits ---
# GitHub shows a commit as Unverified unless it carries a signature from a key
# registered on the account. SSH signing rather than GPG: one key file, no
# gpg-agent, no passphrase daemon to keep alive in a container.
#
# Rebuilt from scratch on every boot, exactly like ~/.devaloy_secrets — clearing
# GIT_SIGNING_SSH_KEY in .env and redeploying really does remove the key AND
# turn commit.gpgsign back off, so a later commit does not fail on a key that is
# no longer there.
#
# The three files are built as staging copies and swapped in by commit_staged
# (common.sh), so a boot with the same key leaves them untouched. SIGNING_OK
# records whether a usable key went in; when it did not, the bottom of this
# step removes all three, which is the revocation half of "from scratch".
step_signing() {
  SIGNING_KEY="${DEV_HOME}/.ssh/devaloy_signing"
  ALLOWED_SIGNERS="${DEV_HOME}/.config/git/allowed_signers"
  SIGNING_OK=0
  rm -f "${SIGNING_KEY}${STAGED}" "${SIGNING_KEY}.pub${STAGED}" "${ALLOWED_SIGNERS}${STAGED}"

  if [ -n "${GIT_SIGNING_SSH_KEY:-}" ]; then
    # Accepts the key either base64-encoded on one line (the documented form —
    # a .env value cannot portably hold the newlines a PEM block needs) or as
    # literal PEM, for the case where it arrives through some other channel.
    KEY_MATERIAL="${GIT_SIGNING_SSH_KEY}"
    case "${KEY_MATERIAL}" in
      *"PRIVATE KEY"*) ;;
      *) KEY_MATERIAL="$(printf '%s' "${KEY_MATERIAL}" | tr -d ' \n' | base64 -d 2>/dev/null || true)" ;;
    esac

    case "${KEY_MATERIAL}" in
      *"PRIVATE KEY"*)
        as_dev "mkdir -p '${DEV_HOME}/.ssh' && chmod 700 '${DEV_HOME}/.ssh'"
        install -m 600 -o "${DEV_USER}" -g "${DEV_USER}" /dev/null "${SIGNING_KEY}${STAGED}"
        # Exactly one trailing newline: OpenSSH rejects a private key without it,
        # and command substitution above already ate any that were there.
        printf '%s\n' "${KEY_MATERIAL}" > "${SIGNING_KEY}${STAGED}"

        # -P '' and </dev/null together are what stop this hanging forever on a
        # passphrase prompt: an encrypted key fails fast here instead, which is
        # the right outcome — nothing in this container can type a passphrase.
        if as_dev "ssh-keygen -y -P '' -f '${SIGNING_KEY}${STAGED}' > '${SIGNING_KEY}.pub${STAGED}'" </dev/null 2>/dev/null &&
           [ -s "${SIGNING_KEY}.pub${STAGED}" ]; then
          commit_staged "${SIGNING_KEY}${STAGED}" "${SIGNING_KEY}"
          commit_staged "${SIGNING_KEY}.pub${STAGED}" "${SIGNING_KEY}.pub"
          SIGNING_OK=1
          git_cfg gpg.format ssh
          # The PRIVATE key path, not the .pub: git hands this straight to
          # `ssh-keygen -Y sign -f`, which needs the secret half and finds the
          # public one beside it.
          git_cfg user.signingkey "${SIGNING_KEY}"
          git_cfg commit.gpgsign true
          # Tags too — GitHub verifies those on the release page as well.
          git_cfg tag.gpgsign true

          # Only affects local `git log --show-signature` output, which without it
          # reports every one of your own commits as from an unknown signer.
          # GitHub does not read this file; it checks the key on your account.
          as_dev "mkdir -p '$(dirname "${ALLOWED_SIGNERS}")'"
          install -m 600 -o "${DEV_USER}" -g "${DEV_USER}" /dev/null "${ALLOWED_SIGNERS}${STAGED}"
          printf '%s %s\n' "${GIT_EMAIL:-dev}" "$(cat "${SIGNING_KEY}.pub")" > "${ALLOWED_SIGNERS}${STAGED}"
          commit_staged "${ALLOWED_SIGNERS}${STAGED}" "${ALLOWED_SIGNERS}"
          git_cfg gpg.ssh.allowedSignersFile "${ALLOWED_SIGNERS}"

          log "commits will be SSH-signed with $(ssh-keygen -lf "${SIGNING_KEY}.pub" 2>/dev/null | awk '{print $2}')"

          # --- register the public half on GitHub as a signing key ---
          # This is what turns the badge from Unverified to Verified, and it is
          # not optional or inferrable: GitHub checks the signature against the
          # keys listed under SSH *signing* keys on the account. A key you already
          # use for authentication does not count, even byte-for-byte identical —
          # it has to be listed under both types. Doing it here means bringing
          # your existing key needs nothing done on github.com.
          #
          # Best-effort on purpose. It needs admin:ssh_signing_key on the PAT
          # (fine-grained: "SSH signing keys" read+write), which a token minted for
          # `git push` will not have. Every failure path prints the manual step and
          # boots on rather than holding the box hostage to a scope.
          if [ -n "${GITHUB_TOKEN:-}" ] && [ -x /usr/local/bin/gh ]; then
            # Match on the key body alone, never the whole line: the comment field
            # differs between the copy on your laptop and the one ssh-keygen -y
            # regenerates here, so comparing lines would re-upload every boot.
            PUB_BODY="$(awk '{print $2}' "${SIGNING_KEY}.pub")"
            # No --paginate: one page of 100 is far past anyone's signing-key count,
            # and paginating an array endpoint hands jq concatenated arrays.
            # shellcheck disable=SC2016  # $HOME is expanded by the dev user's shell.
            SIGNING_KEYS_JSON="$(as_dev '. "$HOME/.devaloy_secrets" && gh api "/user/ssh_signing_keys?per_page=100"' 2>/dev/null || true)"

            if printf '%s' "${SIGNING_KEYS_JSON}" | jq -e --arg k "${PUB_BODY}" \
                 'any(.[]; (.key | split(" ")[1]) == $k)' >/dev/null 2>&1; then
              log "signing key is already registered on GitHub"
            else
              # shellcheck disable=SC2016  # as above.
              ADD_CMD='. "$HOME/.devaloy_secrets" && gh api --method POST /user/ssh_signing_keys'
              ADD_CMD="${ADD_CMD} -f title=$(sq "devaloy (${TS_HOSTNAME:-devaloy})")"
              ADD_CMD="${ADD_CMD} -f key=$(sq "$(cat "${SIGNING_KEY}.pub")")"
              ADD_OUT="$(as_dev "${ADD_CMD}" 2>&1 || true)"
              case "${ADD_OUT}" in
                # Also the path taken when the token can write but not read, so the
                # listing above came back empty and this POST was a no-op.
                *'already in use'*|*'already exists'*)
                  log "signing key is already registered on GitHub" ;;
                *'"id"'*)
                  log "registered the signing key on GitHub — commits will show as Verified" ;;
                *)
                  log "WARNING: could not register the signing key on GitHub."
                  log "WARNING: add ~/.ssh/devaloy_signing.pub by hand at"
                  log "WARNING:   https://github.com/settings/ssh/new  (type: Signing Key)"
                  log "WARNING: or give the PAT the admin:ssh_signing_key scope to"
                  log "WARNING: let this happen on its own. Commits are signed either"
                  log "WARNING: way; GitHub just shows them Unverified until it is done." ;;
              esac
            fi
          else
            log "GitHub marks these Verified only once the matching PUBLIC key is"
            log "added to your account as a SIGNING key (not an authentication key):"
            log "  https://github.com/settings/ssh/new"
          fi
        else
          rm -f "${SIGNING_KEY}${STAGED}" "${SIGNING_KEY}.pub${STAGED}"
          log "WARNING: GIT_SIGNING_SSH_KEY is not a usable key — commits stay unsigned."
          log "WARNING: it must be an OpenSSH private key with NO passphrase."
        fi
        ;;
      *)
        log "WARNING: GIT_SIGNING_SSH_KEY did not decode to an SSH private key."
        log "WARNING: expected base64 of the key file — commits stay unsigned."
        ;;
    esac
  fi

  # No usable key this boot: drop whatever an earlier boot installed.
  if [ "${SIGNING_OK}" != 1 ]; then
    rm -f "${SIGNING_KEY}" "${SIGNING_KEY}.pub" "${ALLOWED_SIGNERS}"
  fi

  # Reached both when no key is configured and when one failed to install, so a
  # box that signed yesterday does not fail every commit today.
  if [ ! -s "${SIGNING_KEY}" ]; then
    git_unset commit.gpgsign
    git_unset tag.gpgsign
    git_unset user.signingkey
    git_unset gpg.format
    git_unset gpg.ssh.allowedSignersFile
  fi
}

# --- clone the repos named in DEVALOY_REPOS ---
# Seeds ~/projects on a fresh box so the first session lands on real code
# instead of an empty home. The list lives in .env, which is gitignored, so no
# repository of yours is ever named in this repository.
#
# Runs LAST of the git blocks on purpose: it clones over HTTPS and relies on the
# credential helper that `gh auth setup-git` installed above. Without a
# GITHUB_TOKEN the public repos in the list still clone and the private ones
# fail one by one, which is the right split.
#
# Every failure here is a warning, never an exit. This block is far below
# tailscaled, and a typo in one URL must not cost you the SSH you would fix it
# from. `set -e` is on, hence the `if !` around the clone rather than a bare
# call, which would take the whole script down on the first bad URL.
step_clone_repos() {
  if [ -n "${DEVALOY_REPOS:-}" ]; then
    PROJECTS_DIR="${DEV_HOME}/projects"
    as_dev "mkdir -p $(sq "${PROJECTS_DIR}")"

    # Word-split on the default IFS, so spaces, tabs and newlines all separate.
    # `set -f` is what makes that safe: a `?` or `*` anywhere in a URL would
    # otherwise glob against the filesystem and expand into something else
    # entirely. Restored right after, because the rest of this script does not
    # expect noglob. The split lands in this function's positional parameters,
    # which nothing else reads.
    set -f
    # shellcheck disable=SC2086  # the split is the point; see the note above.
    set -- ${DEVALOY_REPOS}
    set +f

    for spec in "$@"; do
      # Whitelist, not a blacklist. Every clone below reaches git through
      # `as_dev`, which is `su -c` on ONE string, so a token holding a quote or a
      # semicolon is a command injection with root's environment behind it. The
      # sq() quoting further down is the second layer; this is the first.
      case "${spec}" in
        *[!A-Za-z0-9._:/@+~-]*)
          log "WARNING: DEVALOY_REPOS entry '${spec}' has an illegal character — skipped."
          continue
          ;;
      esac

      # Three accepted forms, matched in order. The shorthand needs exactly one
      # slash and no colon, which is what tells `owner/repo` apart from the SSH
      # form `git@github.com:owner/repo`.
      case "${spec}" in
        https://*|http://*|git@*:*)
          repo_url="${spec}"
          ;;
        */*/*|*:*)
          log "WARNING: DEVALOY_REPOS entry '${spec}' is not a URL or owner/repo — skipped."
          continue
          ;;
        */*)
          repo_url="https://github.com/${spec}"
          ;;
        *)
          log "WARNING: DEVALOY_REPOS entry '${spec}' is not a URL or owner/repo — skipped."
          continue
          ;;
      esac

      # Normalize before taking the basename, so github.com/foo/bar/,
      # github.com/foo/bar and github.com/foo/bar.git all land in ~/projects/bar.
      repo_url="${repo_url%/}"
      repo_name="${repo_url##*/}"
      repo_name="${repo_name##*:}"
      repo_name="${repo_name%.git}"
      if [ -z "${repo_name}" ]; then
        log "WARNING: DEVALOY_REPOS entry '${spec}' names no repository — skipped."
        continue
      fi

      repo_dir="${PROJECTS_DIR}/${repo_name}"
      # Already cloned: silent. This block runs on EVERY boot, and a redeploy of a
      # box with fifteen repos should not print fifteen lines saying so.
      if [ -d "${repo_dir}/.git" ]; then
        continue
      fi
      # Occupied by something that is not a clone. Two repos of the same name from
      # different owners land here, and so does a directory you made by hand.
      # Skipped rather than merged into, because the alternative writes into your
      # work.
      if [ -e "${repo_dir}" ]; then
        log "WARNING: ~/projects/${repo_name} exists and is not a git clone —"
        log "WARNING: '${spec}' skipped. Rename or remove it, then restart."
        continue
      fi

      log "Cloning ${spec} into ~/projects/${repo_name}"
      if ! as_dev "git clone --quiet $(sq "${repo_url}") $(sq "${repo_dir}")" 2>&1; then
        # A half-written directory would be read as "occupied" on the next boot
        # and never retried, so the failed attempt is cleared here.
        rm -rf "${repo_dir}"
        log "WARNING: clone of '${spec}' failed — a private repo needs GITHUB_TOKEN."
      fi
    done
    unset spec repo_url repo_name repo_dir
  fi
}
