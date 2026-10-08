# StatusLineGumbo — a Claude Code status line: project, branch, context, and both usage windows

A status line for Claude Code showing which repo and branch you're in, how much
of the context window you've used, and **both** usage-limit windows — the 5-hour
and the weekly — each with a burn-rate indicator and its reset time:

```
GitGumbo · master
ctx 15% ┃ 5h 42% 8%↓ ↻14:30 ┃ 7d 61% 12%↑ ↻Thu 09:46 ┃ [as of 13:07]
```

- **project** — basename of the git repo root, falling back to the working
  directory (magenta)
- **branch** — current git branch (cyan)
- **ctx NN%** — how much of the context window is used
- **5h NN% / 7d NN%** — how much of each usage-limit window is used
  (green/yellow/red by threshold)
- **pace** — your usage vs. how far through that window you are. `↓` (green)
  = under the linear burn rate, with room to spare; `↑` (yellow/red) =
  burning faster than linear. The 7d number is the one worth
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

## 1. Get the script

Download it to `~/.claude/statusline.sh`:

```sh
curl -fsSL https://raw.githubusercontent.com/shappski/StatusLineGumbo/master/statusline.sh \
  -o ~/.claude/statusline.sh
chmod +x ~/.claude/statusline.sh
```

Or clone the repo and link to it, so a `git pull` is all an update takes:

```sh
git clone https://github.com/shappski/StatusLineGumbo.git ~/StatusLineGumbo
ln -sf ~/StatusLineGumbo/statusline.sh ~/.claude/statusline.sh
```

It's one POSIX `sh` file — [read it](statusline.sh) before you run it.

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
  reads as fully under pace (`↓`) rather than going negative.

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

## License

MIT — see [LICENSE](LICENSE).
