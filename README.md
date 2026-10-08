# Claude Code status line: project, branch, context, and both usage windows

A status line for Claude Code showing which repo and branch you're in, how much
of the context window you've used, and **both** usage-limit windows — the 5-hour
and the weekly — each with a burn-rate indicator and its reset time:

```
GitGumbo · master
ctx 15% · 5h 42% 8%↓behind ↻14:30 · 7d 61% 12%↑ahead ↻Thu 09:46 [as of 13:07]
```

- **project** — basename of the git repo root, falling back to the working
  directory (magenta)
- **branch** — current git branch (cyan)
- **ctx NN%** — how much of the context window is used
- **5h NN% / 7d NN%** — how much of each usage-limit window is used
  (green/yellow/red by threshold)
- **pace** — your usage vs. how far through that window you are. `behind`
  (green) = under the linear burn rate, with room to spare; `ahead`
  (yellow/red) = burning faster than linear. The 7d number is the one worth
  watching — it's the one you can't undo by taking a break for an hour.
- **↻HH:MM** — local clock time that window resets (the weekly one shows the
  weekday too, since it's usually days away)
- **[as of HH:MM]** — when the line was last drawn. It only updates on redraw,
  so this tells you how stale what you're reading is.

The `ctx` slot always renders. When the payload carries no usage yet — session
start, after `/clear`, after auto-compact — it shows `—`, so "no data yet" is
distinguishable from "the status line is broken".

Outside a git repo it drops the branch and names the directory. The `5h` and
`7d` segments only appear on Claude.ai Pro/Max plans, and only after the first
API response of a session — every field falls back to empty if absent. Requires
`jq`, `git`, and `awk` on your `PATH` (all standard).

## 1. Create the script

Save this as `~/.claude/statusline.sh`:

```sh
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
```

Make it executable:

```sh
chmod +x ~/.claude/statusline.sh
```

## 2. Point Claude Code at the script

Add this to `~/.claude/settings.json` (merge it in alongside your existing
settings — don't replace the whole file):

```json
"statusLine": {
  "type": "command",
  "command": "~/.claude/statusline.sh",
  "refreshInterval": 10
}
```

`refreshInterval` is optional; without it the line redraws less often and the
`[as of]` stamp drifts further behind.

⚠️ If the repo you're in has its own `.claude/settings.json` defining
`statusLine`, that one wins and the user-level file is ignored. Precedence,
highest first: `.claude/settings.local.json` → `.claude/settings.json` →
`~/.claude/settings.json`.

## 3. Reload

Restart Claude Code (or it picks up on the next refresh).

## Notes

- **macOS/BSD works.** GNU and BSD `date` share no flags for either job the
  script needs, so both helpers try GNU first and fall back. The one gap is a
  `resets_at` carrying an explicit `±hh:mm` offset rather than a trailing `Z`:
  BSD `date` can't parse it and the `↻` time is omitted. Everything else renders.
- **No `5h …` segment?** You're either not on a Pro/Max plan, or the session
  hasn't made its first API call yet — it appears once usage data exists.
- **`ctx —` on a fresh session is normal**, not a fault. See above.
- The pace figure clamps at 100% elapsed, so a window that has already reset
  reads as fully "behind" rather than going negative.

## Tests

```sh
sh tests/run.sh
```

Golden renders — a fixture payload in, the exact rendered line out, escapes and
all. There is one fixture per behaviour rather than one happy path, because a
single payload can't see drift: an earlier fork of this script sat three weeks
behind the original, and its one golden differed by nothing but a colour code.

`tests/fixtures/payload-no-ctx.json` is a real captured session-start payload,
with the paths replaced so the render is deterministic.
