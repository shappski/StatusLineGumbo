#!/bin/sh
# Regression harness for statusline.sh.
#
# Every case is a golden render: a fixture payload in, the exact rendered line
# out, byte for byte including the ANSI escapes. TZ is pinned and the payloads
# point at /tmp (not a git repo) so the render is deterministic; the only
# volatile part is the "[as of HH:MM]" stamp, which is normalised away.
#
# The reset timestamps in the fixtures are deliberately in the past, so the
# pace calculation clamps at 100% elapsed and the goldens do not rot.
#
# One fixture per behaviour, because a single happy-path payload cannot see
# drift: an earlier fork of this script sat three weeks behind the original and
# its one golden differed by nothing but a colour code.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SCRIPT="$ROOT/statusline.sh"
FIX="$ROOT/tests/fixtures"

TZ=UTC
export TZ

fails=0
pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; fails=$((fails + 1)); }

# Render one fixture, with the volatile clock stamp blanked out.
render() {
    sh "$SCRIPT" < "$FIX/$1.json" \
        | sed 's/\[as of [0-9][0-9]:[0-9][0-9]\]/[as of HH:MM]/'
}

# golden <fixture> <what it proves>
golden() {
    if render "$1" | diff -q - "$FIX/$1.golden" >/dev/null 2>&1; then
        pass "$2"
    else
        fail "$2"
        render "$1" | diff "$FIX/$1.golden" - | cat -v || true
    fi
}

printf 'statusline.sh\n'

golden payload         'renders project, branch slot, ctx, 5h and 7d'
golden payload-iso-reset 'parses an ISO 8601 resets_at, not just an epoch'
golden payload-no-pct  'falls back to total_input_tokens / context_window_size'
golden payload-no-ctx  'renders "—" for context rather than dropping the slot'
golden payload-no-limits 'renders without rate_limits at all'

# The reset time is the whole point of the ISO fixture: an unparsed timestamp
# drops the ↻ segment silently, and the two goldens would still both be "green"
# against themselves. Pin them to each other.
if [ "$(render payload | sed 's/.*↻/↻/')" \
   = "$(render payload-iso-reset | sed 's/.*↻/↻/')" ]; then
    pass 'the ISO and epoch fixtures resolve to the same reset times'
else
    fail 'the ISO and epoch fixtures resolve to the same reset times'
fi

# Exit status is not cosmetic: Claude Code runs this as a command and a
# non-zero exit is how a status line disappears.
for f in payload payload-no-ctx payload-no-limits; do
    if sh "$SCRIPT" < "$FIX/$f.json" >/dev/null 2>&1; then
        pass "exits 0 on $f.json"
    else
        fail "exits 0 on $f.json"
    fi
done

printf '\n'
if [ "$fails" -eq 0 ]; then
    printf 'all statusline tests passed\n'
else
    printf '%s statusline test(s) failed\n' "$fails"
fi
exit "$fails"
