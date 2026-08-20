# YF Builds — dashboard

The team-facing view of the YF Builds registry: every app, page and mock-up the studio
has built with Claude, who built it, what state it's in, and a one-click download of the
latest version of each.

Two variants of the same dashboard live here, because they run in different places.

| File | Runs in | Data access |
| --- | --- | --- |
| `yf-builds-dashboard.artifact.html` | claude.ai (published Artifact) | the viewer's own Notion connector, via the artifact `mcp` capability |
| `yf-builds-dashboard.cowork.html` | Cowork desktop | `window.cowork.callMcpTool` |

Both read the same registry and render the same cards, filters, freshness dots and
Download-latest links. The Cowork variant is the original; the artifact variant exists so
the dashboard can be opened as a plain URL by anyone on the team, without Cowork and
without the connector grants being cleared on every republish.

## How a build gets here

Publishing is done from **Claude Code**, on the builder's own machine:

> "log this build"

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

To refresh them after publishing or changing a build:

```powershell
powershell -File tools/refresh-thumbnails.ps1
```

It renders each build's GitHub Pages URL with headless Chrome, shrinks it to 640x400,
and rewrites the `THUMBS` block in `yf-builds-dashboard.artifact.html`. Republish the
artifact afterwards so the team sees the new tiles. Add new builds to the `$builds` list
at the top of that script.

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
- **Favicon — UNSETTLED, ask ZF before assuming.** This file recorded ⚡; the ZF-PC session
  has published 🛠️ on every publish since the artifact was created, so 🛠️ is what is live
  as of 2026-08-20. Two sessions passing different emoji flip the team's tab icon back and
  forth, which is worse than either choice. **Whoever gets ZF's answer: write the single
  agreed emoji here, delete this paragraph, and use only that one.** It is stored as
  platform metadata and cannot be read back off the live page, which is why it has to be
  recorded rather than checked.
- Pass **nothing** for `capabilities` or `contract`. Omitting them carries the stored
  declaration forward — currently `{mcp}` on contract `0.2.7`. Passing `capabilities`
  explicitly would replace it, and `{}` would clear it and break the page's Notion access.

### Known open item

The connector manifest still declares all three candidate display names — `Notion`,
`notion` and `Notion MCP` — because it was never established which one YF's connector
actually resolves to. The dashboard's **Connection** panel reports the winner. Trim the
manifest to that one and republish. Until then every publish warns that three declared
connectors were unobserved, which is expected and not a failure.
