#!/usr/bin/env bash
# Claude Code status line script (devaloy container edition)
# Reads JSON from stdin, outputs a single formatted status line.
#
# Two deliberate differences from the same script on the Mac:
#   1. No directory segment. Repos are cloned deep under ~/ on this box and a
#      long basename pushed the ctx / 5h / 7d numbers off the right edge of a
#      narrow SSH pane — those numbers matter more here than a name the shell
#      prompt already shows.
#   2. GNU date. Ubuntu has no `date -r` / `date -j -f`, so reset timestamps
#      are parsed with `date -d` (with a BSD fallback so the file stays
#      runnable on macOS).

# ---------------------------------------------------------------------------
# 1. Read stdin
# ---------------------------------------------------------------------------
input=$(cat)

# ---------------------------------------------------------------------------
# 2. ANSI color helpers — Catppuccin Mocha (truecolor)
#    Palette:
#      Green     (0-60%)   — #a6e3a1
#      Lavender  (60-70%)  — #b4befe
#      Peach     (70-80%)  — #fab387
#      Red       (80%+)    — #f38ba8
# ---------------------------------------------------------------------------
RESET="\033[0m"

# Usage-load ramp (applied to ctx / 5h / 7d percentages)
GREEN="\033[38;2;166;227;161m"       # Green    0-60%
LAVENDER="\033[38;2;180;190;254m"    # Lavender 60-70%
PEACH="\033[38;2;250;179;135m"       # Peach    70-80%
SOFT_PINK="\033[38;2;243;139;168m"   # Red      80%+

# Per-segment identity colors
MAUVE="\033[38;2;203;166;247m"       # Mauve    — model name
LABEL="\033[38;2;147;153;178m"       # Overlay2 — segment labels (ctx/5h/7d)
SEP="\033[38;2;88;91;112m"           # Surface2 — separators

# ---------------------------------------------------------------------------
# 3. Parse JSON with jq
# ---------------------------------------------------------------------------
if command -v jq >/dev/null 2>&1; then
    MODEL=$(echo "$input" | jq -r '.model.display_name // "Claude"')

    # Context window used percentage (pre-calculated)
    RAW_CTX=$(echo "$input" | jq -r '.context_window.used_percentage // empty')

    # Context window tokens currently in use
    CTX_TOKENS=$(echo "$input" | jq -r '.context_window.total_input_tokens // empty')

    # Rate limits
    FIVE_H=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
    SEVEN_D=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')

    # Rate-limit window reset times (ISO 8601 or unix epoch)
    FIVE_H_RESET=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')
    SEVEN_D_RESET=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // empty')
else
    MODEL=$(echo "$input" | grep -o '"display_name":"[^"]*"' | head -1 | cut -d'"' -f4)
    MODEL="${MODEL:-Claude}"
    RAW_CTX=""
    CTX_TOKENS=""
    FIVE_H=""
    SEVEN_D=""
    FIVE_H_RESET=""
    SEVEN_D_RESET=""
fi

# ---------------------------------------------------------------------------
# 4. Clamp percentage helper (integer, 0-100)
# ---------------------------------------------------------------------------
clamp_pct() {
    echo "${1:-0}" | awk '{
        v = int($1 + 0.5)
        if (v < 0)   v = 0
        if (v > 100) v = 100
        print v
    }'
}

CTX_PCT=$(clamp_pct "$RAW_CTX")

# ---------------------------------------------------------------------------
# 4a. Format a raw token count -> compact "k" form (e.g. 32700 -> 32.7k)
# ---------------------------------------------------------------------------
fmt_tokens() {
    echo "${1:-0}" | awk '{
        v = $1 + 0
        if (v >= 1000) printf "%.1fk", v / 1000
        else           printf "%d", v
    }'
}

# ---------------------------------------------------------------------------
# 4b. Format a reset timestamp (ISO 8601 or unix epoch) -> local HH:MM
#     GNU date first (this box), BSD date second (so the file also runs on a
#     Mac unchanged). Output is in the container's TZ, which is UTC unless
#     TZ is set in the environment.
# ---------------------------------------------------------------------------
fmt_reset() {
    local ts="$1"
    local fmt="${2:-%H:%M}"
    [ -z "$ts" ] && return
    if [[ "$ts" =~ ^[0-9]+$ ]]; then
        # Unix epoch seconds
        date -d "@$ts" +"$fmt" 2>/dev/null || date -r "$ts" +"$fmt" 2>/dev/null
    else
        # ISO 8601 (e.g. 2026-06-13T15:00:00Z) — parsed as UTC, printed local
        date -d "$ts" +"$fmt" 2>/dev/null || \
            date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "${ts%%[+.Z]*}Z" +"$fmt" 2>/dev/null
    fi
}

# ---------------------------------------------------------------------------
# 5. Color selector based on percentage
# ---------------------------------------------------------------------------
pick_color() {
    local pct="$1"
    if   [ "$pct" -ge 80 ]; then printf '%b' "$SOFT_PINK"
    elif [ "$pct" -ge 70 ]; then printf '%b' "$PEACH"
    elif [ "$pct" -ge 60 ]; then printf '%b' "$LAVENDER"
    else                          printf '%b' "$GREEN"
    fi
}

# ---------------------------------------------------------------------------
# 6. Assemble the status line
# ---------------------------------------------------------------------------

# Separator
BAR_SEP="${SEP} | ${RESET}"

# Model name (mauve)
SEG_MODEL="${MAUVE}${MODEL}${RESET}"

# Context window segment
CTX_COLOR=$(pick_color "$CTX_PCT")
SEG_CTX="${LABEL}ctx${RESET} ${CTX_COLOR}${CTX_PCT}%${RESET}"
if [ -n "$CTX_TOKENS" ]; then
    SEG_CTX="${SEG_CTX} ${LABEL}($(fmt_tokens "$CTX_TOKENS"))${RESET}"
fi

# Build base line
LINE="${SEG_MODEL}${BAR_SEP}${SEG_CTX}"

# 7-day rate limit segment (only when data present)
if [ -n "$SEVEN_D" ]; then
    SD_PCT=$(clamp_pct "$SEVEN_D")
    SD_COLOR=$(pick_color "$SD_PCT")
    LINE="${LINE}${BAR_SEP}${LABEL}7d${RESET} ${SD_COLOR}${SD_PCT}%${RESET}"
    SD_RESET=$(fmt_reset "$SEVEN_D_RESET" "%b %d")
    if [ -n "$SD_RESET" ]; then
        LINE="${LINE} ${LABEL}(${SD_RESET})${RESET}"
    fi
fi

# 5-hour rate limit segment (only when data present)
if [ -n "$FIVE_H" ]; then
    FH_PCT=$(clamp_pct "$FIVE_H")
    FH_COLOR=$(pick_color "$FH_PCT")
    LINE="${LINE}${BAR_SEP}${LABEL}5h${RESET} ${FH_COLOR}${FH_PCT}%${RESET}"
    FH_RESET=$(fmt_reset "$FIVE_H_RESET")
    if [ -n "$FH_RESET" ]; then
        LINE="${LINE} ${LABEL}(${FH_RESET})${RESET}"
    fi
fi

# ---------------------------------------------------------------------------
# 7. Print — printf to honour ANSI escape sequences
# ---------------------------------------------------------------------------
printf '%b\n' "$LINE"
