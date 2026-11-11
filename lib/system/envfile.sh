# shellcheck shell=bash
# devaloy: the env file, shared by the installers.
#
# Sourced, never executed. scripts/install-native.sh keeps /etc/devaloy/env with
# these functions, and the Upstash installer and boot keep
# /workspace/.devaloy/env with the same ones, so both files have one grammar and
# one parser.
#
# The file is a systemd environment file. Every value is written in double
# quotes, with the four characters systemd unescapes inside them (\ " ` $)
# escaped. Inside double quotes systemd keeps every other byte, a newline
# included, so any value survives the trip. It is read back with
# read_env_file, a parser of the same grammar, and never with `source`: a token
# can hold a `$` or a backtick, and a shell would expand them.
#
# The caller owns the key list and the defaults, because each installer has
# its own. Before it calls env_merge or env_render_keys it defines:
#
#   ENV_KEYS          an array of the keys the file holds, in file order
#   env_default KEY   prints the value a key takes when no one set it
#   env_fixed KEY     optional: prints the value of a key that is not an input
#                     and returns 0; returns 1 for every other key
#
# The results are three globals. FILE_VAL and FILE_ORDER hold what the file
# had; VAL holds the merged value of every key in ENV_KEYS. The line below
# makes them global associative arrays even when this file is sourced inside a
# function, where a plain `declare -A` would make locals. -g with no value
# keeps what a caller already declared and filled.
declare -gA FILE_VAL VAL
declare -ga FILE_ORDER

# read_env_file FILE — fill FILE_VAL and FILE_ORDER from a systemd environment
# file. The grammar is systemd's (src/basic/env-file.c): `#` and `;` start a
# comment line; KEY=VALUE, whitespace around the `=` dropped; a double-quoted
# value unescapes \" \\ \` \$, keeps any other backslash pair as it is, drops a
# backslash-newline and keeps a bare newline; a single-quoted value is literal;
# an unquoted value ends at the newline, a backslash takes the next byte
# literally, and trailing blanks go. A line without `=` is skipped, as systemd
# skips it.
read_env_file() {
  local LC_ALL=C
  local data n i c c2 key val
  FILE_VAL=()
  FILE_ORDER=()
  [ -f "$1" ] || return 0
  data="$(cat "$1"; printf x)"
  data="${data%x}"
  n=${#data}
  i=0
  while [ "${i}" -lt "${n}" ]; do
    c="${data:i:1}"
    case "${c}" in
      ' '|$'\t'|$'\n'|$'\r') i=$((i + 1)); continue ;;
      '#'|';')
        while [ "${i}" -lt "${n}" ] && [ "${data:i:1}" != $'\n' ]; do i=$((i + 1)); done
        continue
        ;;
    esac
    key=""
    while [ "${i}" -lt "${n}" ]; do
      c="${data:i:1}"
      [ "${c}" = "=" ] || [ "${c}" = $'\n' ] && break
      key+="${c}"
      i=$((i + 1))
    done
    key="${key%"${key##*[![:space:]]}"}"
    if [ "${c}" != "=" ]; then
      continue
    fi
    i=$((i + 1))
    while [ "${i}" -lt "${n}" ] && { [ "${data:i:1}" = ' ' ] || [ "${data:i:1}" = $'\t' ]; }; do
      i=$((i + 1))
    done
    val=""
    c="${data:i:1}"
    if [ "${c}" = '"' ]; then
      i=$((i + 1))
      while [ "${i}" -lt "${n}" ]; do
        c="${data:i:1}"
        if [ "${c}" = '"' ]; then
          i=$((i + 1))
          break
        elif [ "${c}" = "\\" ]; then
          c2="${data:i+1:1}"
          case "${c2}" in
            '"'|"\\"|'`'|'$') val+="${c2}" ;;
            $'\n') ;;
            *) val+="\\${c2}" ;;
          esac
          i=$((i + 2))
        else
          val+="${c}"
          i=$((i + 1))
        fi
      done
    elif [ "${c}" = "'" ]; then
      i=$((i + 1))
      while [ "${i}" -lt "${n}" ] && [ "${data:i:1}" != "'" ]; do
        val+="${data:i:1}"
        i=$((i + 1))
      done
      i=$((i + 1))
    else
      while [ "${i}" -lt "${n}" ] && [ "${data:i:1}" != $'\n' ]; do
        c="${data:i:1}"
        if [ "${c}" = "\\" ]; then
          c2="${data:i+1:1}"
          [ "${c2}" = $'\n' ] || val+="${c2}"
          i=$((i + 2))
        else
          val+="${c}"
          i=$((i + 1))
        fi
      done
      val="${val%"${val##*[![:space:]]}"}"
    fi
    # Anything after a closing quote up to the newline is dropped.
    while [ "${i}" -lt "${n}" ] && [ "${data:i:1}" != $'\n' ]; do i=$((i + 1)); done
    case "${key}" in
      ''|[0-9]*|*[!A-Za-z0-9_]*) continue ;;
    esac
    [ -n "${FILE_VAL[${key}]+set}" ] || FILE_ORDER+=("${key}")
    FILE_VAL[${key}]="${val}"
  done
}

env_quote() { # env_quote VALUE — the double-quoted form systemd reads back
  local v="$1"
  v="${v//\\/\\\\}"
  v="${v//\"/\\\"}"
  v="${v//\`/\\\`}"
  v="${v//\$/\\\$}"
  printf '"%s"' "${v}"
}

is_env_key() {
  local k
  for k in "${ENV_KEYS[@]}"; do [ "${k}" = "$1" ] && return 0; done
  return 1
}

# env_merge FILE — fill VAL from the environment, FILE and the defaults. A
# non-empty environment variable wins, then the file, then env_default. A key
# env_fixed answers for is not an input: it takes that value whatever the
# environment and the file say. FILE_VAL and FILE_ORDER are left holding the
# file, for env_render_keys.
env_merge() {
  local k envv fixed
  read_env_file "$1"
  for k in "${ENV_KEYS[@]}"; do
    envv="${!k:-}"
    if declare -F env_fixed >/dev/null && fixed="$(env_fixed "${k}")"; then
      VAL[${k}]="${fixed}"
    elif [ -n "${envv}" ]; then
      VAL[${k}]="${envv}"
    elif [ -n "${FILE_VAL[${k}]:-}" ]; then
      VAL[${k}]="${FILE_VAL[${k}]}"
    else
      VAL[${k}]="$(env_default "${k}")"
    fi
  done
}

# env_render_keys — the KEY="VALUE" lines of the file: every key in ENV_KEYS
# from VAL, then each key someone added by hand, from FILE_VAL, in the order
# it had. The caller prints its own comment header first.
env_render_keys() {
  local k
  for k in "${ENV_KEYS[@]}"; do
    printf '%s=%s\n' "${k}" "$(env_quote "${VAL[${k}]}")"
  done
  for k in "${FILE_ORDER[@]}"; do
    is_env_key "${k}" && continue
    printf '%s=%s\n' "${k}" "$(env_quote "${FILE_VAL[${k}]}")"
  done
}
