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
