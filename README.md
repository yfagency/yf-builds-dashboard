# YF / Bridge

YF's internal operating surface, and the repo that builds it. **Bridge** is the app;
**Builds** and **Briefing** are its two sections. Named 2026-08-21 (it was previously
called YF Builds, after the only section it then had).

The mark between the letters is `&#9585;` (U+2571) &mdash; the forward-leaning
diagonal. It is not a backslash and not U+27CD; getting it wrong is the most common
mistake in docs about this page.

| Section | Route | Reads | Written by |
| --- | --- | --- | --- |
| Home | `#/` | both of the below | - |
| Builds | `#/builds` | YF Builds registry, `collection://10d63098-...` | the `yf-builds-publish` skill, plus the 06:30 JST GitHub sync |
| Briefing | `#/briefing` | AI Briefing Archive, `collection://4ebf7258-...` | the `yf-daily-ai-briefing` cron, 07:00 JST |

Routing is hash-based and client-side: one artifact, one URL, one connector grant per
viewer. Anything not starting `#/` is left alone, because the in-page Guide uses plain
`#g-...` anchors of its own.

Two variants of the dashboard live here, because they run in different places.

| File | Runs in | Data access |
| --- | --- | --- |
| `yf-builds-dashboard.artifact.html` | claude.ai (published Artifact) | the viewer's own Notion connector, via the artifact `mcp` capability |
| `yf-builds-dashboard.cowork.html` | Cowork desktop | `window.cowork.callMcpTool` |

The artifact variant is the one the team opens and the only one that is Bridge. **The
Cowork variant was not carried forward on 2026-08-21** &mdash; it is still a builds-only
dashboard with no home page and no Briefing section. Treat it as frozen unless someone
actually needs it.

## How a build gets here

Publishing is done from **Claude Code**, on the builder's own machine:

> "push this build"

That creates a public GitHub repo under the `yfagency` org, pushes the files, and registers
the row. Cowork cannot push to GitHub — its sandbox proxy refuses to supply credentials for
repos outside a preconfigured set — which is why publishing lives in Claude Code and only
there.

The `[YF Build]` prefix on a repo's GitHub description is load-bearing: the daily sync
discovers builds by reading the org's repo listing and filtering on it. A repo without the
prefix never appears on the dashboard.

## Editing the dashboard

Both files are single, self-contained HTML documents — no build step, no dependencies. The
registry's data source IDs and the SQL the page runs are at the top of each `<script>`
block. Change the query there if the registry schema changes.

The artifact variant declares its connector manifest at publish time, not in the file. It is
republished with the Claude Code `Artifact` tool against the same URL, which keeps the link
the team has bookmarked.

## Notes

- The registry's `Commit`, `Last Committer` and `Last Commit` fields are owned by the daily
  06:30 JST sync. Nothing in this repo should write to them.
- `Builder` is who the team says made a build; `Last Committer` is what git recorded. They
  are deliberately separate.
- Builds are public by design — that is what lets anyone download one without a GitHub
  account. Nothing secret belongs in a build.

## Thumbnails

The dashboard shows a thumbnail per build. They are baked into the page as data URIs
because the artifact CSP blocks every external host — a remote `<img>` cannot load, and
neither can an `<iframe>` of the build itself, so a live preview is impossible by
construction. `thumbs/` holds the rendered JPEGs.

**Nobody has to ask for a thumbnail, and nobody has to run anything.** The `Thumbnails`
workflow (`.github/workflows/thumbnails.yml`) checks every two hours, finds every live
build, renders the ones with no image, bakes the set into the page and commits.

**The schedule is the only path most of the team has, which is why it is frequent.** Both
`workflow_dispatch` and `repository_dispatch` require write access to *this* repo, and the
org's default repository permission is `read` — JK and PS have `push=false` here, so a
manual trigger 403s for them. Handing two people a button nobody else can press is not a
fix, so the automatic path runs often enough that the button is not needed: publish a build
and its thumbnail lands within two hours, with no command run by anyone.

That is affordable because of the plan gate. A tick with nothing to do is one
dependency-free `node` run — a repo listing and fifteen probes, a few seconds — and skips
the ~40s renderer install entirely. Only a tick with real work pays for Chrome.

It discovers builds rather than reading a list: every repo in the org whose description
starts with `[YF Build]`, minus the ones whose Pages URL does not answer 200. That second
filter is why `yf-builds-dashboard` and `test-page` drop out on their own and why there is
no exclude list to keep in step.

**`thumbs/builds.txt` is now generated output**, not input. It records what got tiled.
Adding a slug to it does nothing.

That matters because the list *was* the input twice, and both times the same thing
happened: a build was published correctly, registered correctly, served correctly, and got
a hazard tile because its slug never reached a file only two people could push.
`yf-operating-model-visualization` on 2026-08-21, `yf-brand-os-visuals` the same week —
both published by PS, neither of whom could have fixed it. Moving the list from a
PowerShell array into a text file made the manual step easier, not unnecessary. Deriving
it removes the step.

**ZF and BB only** — to re-render an existing tile, say after changing a build's design:

```bash
gh workflow run Thumbnails --repo yfagency/yf-builds-dashboard -f force=work-mosaic
```

`force=all` re-renders everything. Do not put either command in team-facing docs.

Default runs render **only** builds with no image on disk. Animated and WebGL builds do not
capture byte-identically twice, so re-rendering everything on every tick would churn a 600KB
diff and bury the one change that mattered.

**Republishing the artifact is still ZF's, and always will be.** The CSP forces the images
to be data URIs inside the page, and only ZF's account can republish it. So the workflow
gets the repo right and then opens a single `republish-due` issue assigned to ZF, updating
it rather than opening a new one each run. A green run with no issue means there is nothing
to do.

So the honest end-to-end answer, for anyone asking whether a builder can do all of this
alone: they can publish the repo, get the registry row, and get the thumbnail rendered
without help — the last of those within two hours and with no command. **They cannot make
it visible.** The tile appears on Bridge when ZF republishes, and no amount of automation
here changes that. One further thing only ZF can do is add a new person to the `yfagency`
org, which publishing requires at all:
`gh api -X PUT orgs/yfagency/memberships/{github-username} -f role=member`.

### Rendering locally

`tools/refresh-thumbnails.ps1` and `tools/add-thumbnail.py` still work and are unchanged in
behaviour, but they are fallbacks now — for checking a capture on your own machine before CI
takes it. Everything below about their quirks still holds.

### Adding a single build

```bash
python tools/add-thumbnail.py <slug>
```

Renders one build and inserts one entry, leaving the other data URIs byte-for-byte
untouched. Re-running it on a slug that already has a tile refreshes that tile in place.
Needs `pip install websocket-client pillow`.

Prefer this when you have published one build. Two reasons it exists rather than just
running the PowerShell script:

- **`--screenshot` does not work under the Claude Code sandbox.** Chrome runs there and
  has network — `--dump-dom` returns a page — but its *file writes* are blocked, so every
  build reports `did not render - skipped` and the PowerShell script aborts without
  touching the HTML. That abort is correct behaviour, not a bug; it is protecting the
  page. The Python tool drives Chrome over the DevTools protocol instead, so the image
  comes back as base64 over the wire and Python writes it. Verified 2026-08-20 on
  ZF-Laptop with Chrome 151.
- **A one-build addition should not churn the other six.** The PowerShell script rewrites
  the whole `THUMBS` block, so adding one tile rewrites every data URI in the page.

The capture is deterministic: re-rendering an unchanged build produces a byte-identical
JPEG, so a no-op run leaves a clean `git diff`.

## The daily code

Top right of the home masthead. Four capsules, each with a lamp above it. Guess the
four-digit code; after each guess the lamps read:

| Lamp | Meaning |
| --- | --- |
| green | right digit, right slot |
| amber | that digit is in the code, but not in this slot |
| red | that digit is not in the code at all |

**The lamps show the last guess only** — that is the design, not a limitation. A quiet guess
log sits underneath, newest first, because without it the game is played on a scrap of
paper next to the keyboard.

**The four digits never repeat, and that is load-bearing.** The three verdicts each have
exactly one meaning while no digit repeats; with a repeated digit, "in the code but not in
this slot" stops being answerable per position without inventing a tie-break the player
cannot see.

Unlimited guesses, no clock — the game ends when you crack it. Cracking it first go is 140
points, every further guess costs 10, floor of 20. Nothing is scored on time: a thinking
game should not punish thinking.

The code is generated from the date — `mulberry32` seeded by a hash of the JST day — so
everyone gets the same code without it being stored anywhere, which is what makes a
leaderboard mean something and also means there is no code sitting in a database for
somebody to read. It rolls over at Tokyo midnight, not at each viewer's own.

Progress survives closing the sheet but not a reload. The code is derivable from the day;
the guesses already spent are not worth a round trip to store.

*This slot held a JST clock, then a guess-the-build-thumbnail game, before this. Both are
gone.*

**Scores live in Notion**, `collection://a4e41bd8-be65-4f23-9f6a-8f3edd0dae88` (KB → Bridge
Play), one row per person per day: `Opens`, `Played`, `Score`, `Guesses`, `Took`. Read and
written with the viewer's own connector like every other write in this page.

Three stores were considered and two rejected. `localStorage` cannot work — a leaderboard
the others cannot see is not a leaderboard. The `artifact` capability cannot either: writes
need owner-or-editor, so PS and JK would be rejected, and it would republish the whole page
per score. The `db` capability would have been the natural fit and is **not on this
account's roster** (only `artifact`, `downloads`, `mcp`, `self`), so Notion it is.

**The ranked number is points, and the streak is capped at one a day by construction.**
`Opens` is recorded and displayed because ZF asked for it, but nothing is ranked on it:
ranking on opens rewards reloading the page. If that changes, change it deliberately.

A viewer with no Notion write access simply is not recorded. The game is not worth an error
banner over.

### Duplicate rows are expected, and the reader copes

Two rows for one person-day happen: `countOpen` and `savePlay` each create one when the
re-read hasn't landed, and two tabs race past any in-page guard. **Notion has no unique
constraint and no delete**, so there is no way to prevent or clean this at the source.

Two layers handle it. Writes are serialised through `PLAY_READY` so one page cannot do it
to itself, and the reader tolerates what slips through: `rowFor` prefers a row that
recorded a result over a blank twin, and `standings` collapses per person-day taking the
**max** of each number before summing across days. Summing straight over the rows
double-counted — that is why ZF's opens once read 5 on a day with four visits.

### Resetting, on #/dev

ZF only. Four controls under **Game data**:

| Control | Scope |
| --- | --- |
| Reset all | every row, every person |
| Reset person | one person, all days |
| Reset day | one JST day, one person or everyone |
| Practice | replay today's code, writing nothing |

Every destructive button takes **two clicks**, and the second one is labelled with the row
count it is about to zero (`Zero 3 rows?`). The arm times out after six seconds so a
half-finished click cannot be completed by accident later.

**A reset writes zeros; it does not delete.** The rows stay in Notion and the previous
numbers are gone for good — there is no undo of any kind. The leaderboard sums, so zeroed
rows read as a clean slate.

**Practice mode is in-memory on purpose.** It replays today's code as often as you like and
skips the save entirely, which is the only way to retry without a second score reaching the
leaderboard. A reload clears it, so it cannot be left on by accident for a week.

## Before you publish - every time, both sessions

An artifact publish does **not** go through git. Two Claude sessions publish this one
page, so whoever publishes last silently overwrites the other, and neither is told. That
happened twice on 2026-08-20: a whole-file edit re-encoded every non-ASCII character into
mojibake, and a publish from a stale copy dropped a thumbnail another session had just
added. Both are now checked mechanically:

```powershell
git pull
powershell -File tools/check-artifact.ps1
```

It exits non-zero and tells you what is wrong if the file is not pure ASCII, if a rendered
thumbnail in `thumbs/` is missing from the page, if the markup or script brackets are
unbalanced, if a stray fragment sits above the `<title>`, if the guide's contents rail
points at a section that does not exist, or **if you are behind the remote** - which is
the one that catches you about to overwrite another session.

Publish only on exit code 0, then commit and push so the repo matches what is live. The
repo is the shared state; the artifact is a copy of it.

## Republishing the artifact

From Claude Code, with the `Artifact` tool, passing the existing artifact URL so the
team's bookmark keeps working:

- URL: `https://claude.ai/code/artifact/89f3d2c0-86ef-4561-8c51-2778f38aad48`
- **Favicon: 🛠️ — SETTLED by ZF, 2026-08-21. Do not substitute anything else, ever.**
  Hammer and wrench, `U+1F6E0 U+FE0F`. Pass exactly this on every publish. It is stored as
  platform metadata and cannot be read back off the live page, which is why it lives here
  and why `tools/check-artifact.ps1` prints it on every run: no session should ever have to
  ask, guess, or raise it with ZF again. An earlier version of this file said ⚡; that was
  wrong and is now void.
- Pass **nothing** for `capabilities` or `contract`. Omitting them carries the stored
  declaration forward — currently `{mcp}` on contract `0.2.7`. Passing `capabilities`
  explicitly would replace it, and `{}` would clear it and break the page's Notion access.

### Known open item

The connector manifest still declares all three candidate display names — `Notion`,
`notion` and `Notion MCP` — because it was never established which one YF's connector
actually resolves to. The dashboard's **Connection** panel reports the winner. Trim the
manifest to that one and republish. Until then every publish warns that three declared
connectors were unobserved, which is expected and not a failure.

## Seeing the page before you publish it

Neither Claude session can open the live artifact, so styling it blind is how bad layout
ships. `tools/preview-stub.html` is a fake artifact runtime: insert it immediately before
the page's own `<script>` and the file renders locally, with sample builds, one of them
checked out.

```powershell
$dir = "."   # repo root
$stub = Get-Content tools/preview-stub.html -Raw
$src  = [IO.File]::ReadAllText("$dir/yf-builds-dashboard.artifact.html")
$i = $src.IndexOf("`n<script>`n")
[IO.File]::WriteAllText("$env:TEMP/preview.html", $src.Substring(0,$i+1) + $stub + $src.Substring($i+1), (New-Object System.Text.UTF8Encoding($false)))
& "C:\Program Files\Google\Chrome\Application\chrome.exe" --headless=new --disable-gpu `
  --enable-unsafe-swiftshader --hide-scrollbars --no-first-run --window-size=1280,900 `
  --virtual-time-budget=6000 --screenshot="$env:TEMP/preview.png" "file:///$env:TEMP/preview.html"
```

Then look at the PNG. This caught two bugs that static reading did not: a `[hidden]`
element staying visible because an author `display: flex` beats the UA stylesheet, and a
near-empty row on every card. **Never commit the merged preview file** - it contains a
stub that fakes the registry.

### When the PowerShell script renders nothing

If every build reports `did not render - skipped`, the Chrome calls are being blocked, and
the cause depends on how the script was started. Verified 2026-08-21 on ZF-PC:

- **Run by a person in a terminal:** works.
- **Run by Claude as a child process** (`powershell -File tools/refresh-thumbnails.ps1`):
  every screenshot fails. The child gets a stricter sandbox than the session's own shell,
  and Chrome's file writes are blocked inside it. The same Chrome command line, with the
  same flags and the same output path, succeeds when Claude runs it directly in its
  PowerShell tool rather than through a spawned script.

So when Claude needs to refresh thumbnails, it should run the render loop and the `THUMBS`
injection **inline** rather than invoking this script, or use `tools/add-thumbnail.py`
where Python is available. The script's abort is correct behaviour either way: it refuses
to rewrite the page from an empty render set.
