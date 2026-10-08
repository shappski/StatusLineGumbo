#!/bin/sh
# Statusline: "<project> · <branch>" / "ctx <pct>% · 5h <pct>% <pace> ↻<reset> · 7d <pct>% <pace> ↻<reset> [as of <hh:mm>]"
#   project — basename of the git repo root (falls back to the working dir)
#   branch  — git branch in the payload's working dir
#   ctx     — context window used; the slot always renders, showing "—" when the
#             payload carries no usage yet (session start, /clear, auto-compact),
#             so "no data" is distinguishable from a broken statusline
#   5h/7d   — usage-limit window used (rate_limits.<window>.used_percentage)
#   pace    — used% vs how far through the window we are; "behind" = under the
#             linear burn rate (room to spare), "ahead" = burning faster than linear
#   ↻reset  — local clock time the window resets (rate_limits.<window>.resets_at)
# rate_limits exist only for Claude.ai Pro/Max after the first API response, and
# each window may be absent — every read falls back to empty.
input=$(cat)

# ANSI colors
C_PROJECT='\033[1;35m' # bold magenta
C_BRANCH='\033[36m'    # cyan
C_LABEL='\033[2m'      # dim grey
C_GREEN='\033[32m'
C_YELLOW='\033[33m'
C_RED='\033[31m'
C_RESET='\033[0m'

# Color a percentage by usage threshold: <50 green, <80 yellow, else red.
pct_color() {
    awk -v p="$1" 'BEGIN{ if(p<50) print "\033[32m"; else if(p<80) print "\033[33m"; else print "\033[31m" }'
}

# GNU and BSD date share no flags for either job below, so each helper tries GNU
# first and falls back. Both failing is not an error: the caller drops the ↻
# segment rather than render a wrong time.

# resets_at is an epoch number on some builds and an ISO 8601 string on others.
reset_epoch() {
    case "$1" in
        '')       return 0 ;;
        *[!0-9]*) ;;                          # not a bare epoch — parse below
        *)        printf '%s' "$1"; return 0 ;;
    esac
    date -d "$1" +%s 2>/dev/null && return 0
    # BSD date cannot guess a layout, so it is spelled out. This covers the
    # trailing-Z form; an explicit ±hh:mm offset is not parsed there and the
    # reset time is simply omitted.
    case "$1" in
        *Z) iso=${1%Z}; iso=${iso%%.*}
            TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%S' "$iso" +%s 2>/dev/null ;;
    esac
}

# epoch seconds -> local clock time in the given strftime format
epoch_time() {
    date -d "@$1" "+$2" 2>/dev/null || date -r "$1" "+$2" 2>/dev/null
}

# window <label> <used_pct> <resets_at> <window_seconds> <reset_strftime>
window() {
    label=$1 used=$2 reset=$3 span=$4 rfmt=$5
    [ -n "$used" ] || return 0
    [ -n "$out" ] && out="$out ${C_LABEL}·${C_RESET} "
    out="$out${C_LABEL}${label}${C_RESET} $(pct_color "$used")$(printf '%.0f%%' "$used")${C_RESET}"

    epoch=$(reset_epoch "$reset")
    [ -n "$epoch" ] || return 0

    # start = reset - span; pace = used% - elapsed%
    pace=$(awk -v reset="$epoch" -v now="$(date +%s)" -v used="$used" -v span="$span" 'BEGIN{
        el=(now-(reset-span))/span*100;
        if(el<0)el=0; if(el>100)el=100;
        printf "%.0f", used-el
    }')
    if [ "$pace" -lt 0 ] 2>/dev/null; then
        out="$out ${C_GREEN}$(( -pace ))%↓behind${C_RESET}"
    elif [ "$pace" -gt 0 ] 2>/dev/null; then
        pc="$C_YELLOW"; [ "$pace" -ge 10 ] && pc="$C_RED"
        out="$out ${pc}${pace}%↑ahead${C_RESET}"
    else
        out="$out ${C_LABEL}on pace${C_RESET}"
    fi

    rtime=$(epoch_time "$epoch" "$rfmt")
    [ -n "$rtime" ] && out="$out ${C_LABEL}↻${rtime}${C_RESET}"
}

dir=$(printf '%s' "$input" | jq -r '.workspace.current_dir // empty')
root=$(git -C "${dir:-.}" rev-parse --show-toplevel 2>/dev/null)
project=$(basename "${root:-${dir:-.}}")
branch=$(git -C "${dir:-.}" rev-parse --abbrev-ref HEAD 2>/dev/null)

eval "$(printf '%s' "$input" | jq -r '
    @sh "ctx=\(.context_window.used_percentage // "")",
    @sh "ctx_tokens=\(.context_window.total_input_tokens // "")",
    @sh "ctx_size=\(.context_window.context_window_size // "")",
    @sh "five_pct=\(.rate_limits.five_hour.used_percentage // "")",
    @sh "five_reset=\(.rate_limits.five_hour.resets_at // "")",
    @sh "seven_pct=\(.rate_limits.seven_day.used_percentage // "")",
    @sh "seven_reset=\(.rate_limits.seven_day.resets_at // "")"
')"

out=""
[ -n "$project" ] && out="${C_PROJECT}${project}${C_RESET}"

if [ -n "$branch" ]; then
    [ -n "$out" ] && out="$out ${C_LABEL}·${C_RESET} "
    out="$out${C_BRANCH}${branch}${C_RESET}"
fi

if [ -n "$ctx" ]; then
    ctx_txt=$(printf '%.0f%%' "$ctx")
elif [ "$ctx_tokens" -gt 0 ] 2>/dev/null && [ "$ctx_size" -gt 0 ] 2>/dev/null; then
    ctx_txt=$(awk -v t="$ctx_tokens" -v s="$ctx_size" 'BEGIN{printf "%.0f%%", t/s*100}')
else
    ctx_txt='—'
fi
# stats start a second line, so a long project or branch name never pushes them off-screen
[ -n "$out" ] && out="$out\n"
out="$out${C_LABEL}ctx${C_RESET} $ctx_txt"

window 5h "$five_pct"  "$five_reset"  18000   '%H:%M'
window 7d "$seven_pct" "$seven_reset" 604800  '%a %H:%M'

# render time — the line only updates on redraw, so this flags how stale it is
[ -n "$out" ] && out="$out "
out="$out${C_LABEL}[as of $(date '+%H:%M')]${C_RESET}"

printf '%b' "$out"
