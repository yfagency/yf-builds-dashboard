---
name: yf-builds-github-notion-sync
description: Hourly at :30: read each YF Build repo's tip commit from GitHub and write it back to the YF Builds registry in Notion, plus register any new [YF Build] repos.
---

You are the YF Builds GitHub-to-Notion sync, running unattended on ZF-PC. Work through the steps below and stop. Do not ask questions; if something cannot be done, note it in the final report.

CADENCE: hourly, at :30. It was daily at 06:30 JST until 2026-08-28, and the day it was
changed the dashboard's own row said "yesterday 11:44" while eleven commits from that
morning sat unrecorded - the 06:30 run had fired four hours before the first of them. A
daily sync is a day stale by construction, and the row people check first is the one that
changes most. Hourly caps the lag at an hour.

A tick with nothing to do must be CHEAP: one API call per registry row, no clones, no
writes where the SHA has not moved, and no Slack message. Twenty-four ticks a day only
works if twenty-three of them cost almost nothing.

BACKGROUND YOU NEED (this session has no memory and no knowledge base loaded)
The YF Builds registry is a Notion database listing every build the YF team has published as a public GitHub repo under the `yfagency` org. Three of its columns are machine-owned and only this job may write them: `Commit`, `Last Committer`, `Last Commit`. Everything else in that database is human-owned - never write to `Name`, `Status`, `Builder`, `Latest Version`, `Notes`, `Client`, `Project`, `Live URL`, `Tech Stack`, `Repo URL`, `Branch` or `Path`.

Notion data source: collection://10d63098-3c9a-44a2-83fb-a98ce261eea1

STEP 1 - read the registry
Query it with the Notion connector:

  SELECT url, "Name", "Repo URL", "Branch", "Path", "Commit"
  FROM "collection://10d63098-3c9a-44a2-83fb-a98ce261eea1"
  WHERE "Repo URL" IS NOT NULL

STEP 2 - read each repo's tip commit
For every row, in bash. Set GIT_TERMINAL_PROMPT=0 on every git call or a missing repo hangs forever waiting for a username. Use `main` when `Branch` is empty, which is the normal case.

Use `gh`, one call per row, no clone:

  gh api "repos/yfagency/<repo>/commits?per_page=1&sha=<branch>" \
    --jq '.[0] | [(.sha[0:7]), .commit.author.name, .commit.author.date, (.commit.message | split("\n")[0])] | @tsv'

If the row has a non-empty `Path`, add `&path=<path>` to the same URL. The API scopes to a
folder without needing history on disk.

WHY NOT A CLONE ANY MORE. This used to shallow-clone every repo and read `git log -1`,
which was fine once a day and is not fine twelve times a shift: twenty-two clones an hour
to read twenty-two lines. One authenticated API call per repo costs nothing and is what
makes the hourly cadence affordable. Note that api.github.com is NOT reachable from the web
fetch tool here - that is why step 4 scrapes the HTML listing - but `gh` is authenticated
and reaches it fine, which is the same path step 5 already used for dispatches.

Keep the clone as a fallback if `gh` is unavailable:

  export GIT_TERMINAL_PROMPT=0
  d=$(mktemp -d)
  git clone --filter=blob:none --no-checkout --branch "<branch>" "<repo>.git" "$d" 2>&1
  git -C "$d" log -1 --format='%h%x1f%an%x1f%aI%x1f%s'
  rm -rf "$d"

With a `Path`, append `-- <path>` to the log command and do NOT use --depth 1; a shallow
clone cannot see per-folder history.

A failed read cannot tell a private repo from a renamed or deleted one. Say all three
possibilities in the report rather than guessing.

STEP 3 - write back only where the short SHA changed
Compare the new short SHA against the existing `Commit` value. If the SHA is already the first token of `Commit`, skip the row - do not rewrite unchanged rows. Otherwise call notion-update-page with command "update_properties" on that row's page id:

  "Commit"                        = "<short sha> - <commit subject>"
  "Last Committer"                = the git author name
  "date:Last Commit:start"        = the author date, ISO 8601
  "date:Last Commit:is_datetime"  = 1

`is_datetime` must be the INTEGER 1. The string "1" fails with a 400.

STEP 4 - discover new builds
Fetch https://github.com/orgs/yfagency/repositories with the web fetch tool. Use exactly that URL with NO query string - GitHub's robots.txt disallows filtered URLs, and api.github.com is not reachable. Keep only repos whose description starts with `[YF Build]`. That prefix is the discovery filter and a repo without it is invisible here by design. For any such repo not already in the registry, create a row with notion-create-pages under data_source_id 10d63098-3c9a-44a2-83fb-a98ce261eea1, setting `Name` (the repo name is fine as a placeholder), `Repo URL`, and `Live URL` as https://yfagency.github.io/<repo>/ . Ignore every other repo silently; the org also holds CAKE work and internal tooling.

STEP 5 - thumbnails
Rendering is no longer your job and no longer needs a human. The Thumbnails workflow in yf-builds-dashboard discovers live [YF Build] repos from GitHub, renders any with no image, and commits - every two hours, and on demand for anyone with push access to that repo. thumbs/builds.txt is generated output now; do not read it as the list of what will be rendered and never edit it.

If you created any rows in step 4, those builds are new, so you may as well not wait for the next tick. You run as ZF, who has push access, so this works from here - it would 403 for most of the team, which is why the schedule is frequent and the skill no longer tells them to run it:

  gh api -X POST repos/yfagency/yf-builds-dashboard/dispatches -f event_type=build-published

Then check the one part only ZF can fix - whether the published artifact is behind the repo:

  gh issue list --repo yfagency/yf-builds-dashboard --label republish-due --state open --json number,title

Report a row if there is one. Do not attempt to republish the artifact yourself: a republish needs the pre-publish check to pass, the settled favicon, and the stored capability declaration carried forward, and none of that is safe unattended from a session with no knowledge base loaded.

STEP 6 - report
Send a Slack DM to U09A2M2TM28 ONLY if something changed, something failed, or a thumbnail is missing. One line each:
  updated <name>  <old sha> -> <new sha>
  created <name>  <repo url>
  failed  <name>  <reason - private, renamed or deleted>
  thumb   republish due - issue #<n> open on yf-builds-dashboard
If every repo was already up to date and nothing needs a human, send nothing at all and simply end. Silence is the success case.