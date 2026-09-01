// Discovers every live YF Build, renders the ones with no thumbnail, and bakes the
// whole set into the dashboard page as data URIs.
//
// WHY THIS EXISTS. The dashboard runs as a claude.ai Artifact under a CSP that blocks
// every external host, so a remote <img> cannot load and an <iframe> of the build cannot
// either. A thumbnail has to already be inside the page. That much is fixed by the
// platform and is not going to change.
//
// What was NOT fixed by the platform was who had to remember. The slug list started as a
// hardcoded array in tools/refresh-thumbnails.ps1, then became thumbs/builds.txt, and both
// times a newly published build got no thumbnail until a human edited a file in a repo
// they usually cannot push to. It happened twice inside a week — yf-operating-model-
// visualization and yf-brand-os-visuals, both published by someone other than the two
// people with write access here. So the list is no longer an input. This script derives it
// from GitHub every run:
//
//   1. every repo in the org whose description starts with "[YF Build]"
//   2. minus the ones whose Pages URL does not answer 200
//
// Filter 2 does the work an exclude list used to: yf-builds-dashboard and test-page are
// tagged [YF Build] but serve nothing, so they drop out on their own. Nobody maintains
// anything. thumbs/builds.txt is now OUTPUT — a record of what got tiled, not the source.
//
// Usage:
//   node tools/render-thumbnails.mjs                 # render only builds with no image
//   FORCE=all node tools/render-thumbnails.mjs       # re-render everything
//   FORCE=slug-a,slug-b node tools/render-thumbnails.mjs
//
// Default is missing-only on purpose. Animated and WebGL builds do not capture
// byte-identically twice, so re-rendering the whole set daily would churn a 600KB diff
// every night and bury the one change that mattered.

import { readFileSync, writeFileSync, existsSync, mkdirSync, readdirSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

// puppeteer and sharp are imported LAZILY, further down, only when something actually needs
// rendering. That is what lets PLAN_ONLY=1 run with no dependencies installed at all: the
// workflow runs a plan pass first and skips a ~40s npm install on the runs - most of them -
// where every build already has an image. Without this the schedule could not be frequent
// enough to make a manual trigger unnecessary.
let sharp;

const ORG = "yfagency";
const HTML = "yf-builds-dashboard.artifact.html";
const SHOT_DIR = "thumbs";
const LIST_FILE = join(SHOT_DIR, "builds.txt");
const WIDTH = 640;
const HEIGHT = 400;
const QUALITY = 62;

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "..");
process.chdir(repoRoot);

const force = (process.env.FORCE ?? "").trim();
const forceAll = force === "all";
const forceList = forceAll
  ? []
  : force.split(",").map((s) => s.trim()).filter(Boolean);

const liveUrl = (slug) => `https://${ORG}.github.io/${slug}/`;
const jpgPath = (slug) => join(SHOT_DIR, `${slug}.jpg`);

// ---------------------------------------------------------------- discovery

// The org's repos are public, so the workflow's own GITHUB_TOKEN is enough. It is sent
// when present purely to get the authenticated rate limit; the call works without one,
// which is what lets this script run on a laptop with no token in the environment.
async function gh(path) {
  const headers = { Accept: "application/vnd.github+json", "User-Agent": "yf-builds-thumbnails" };
  if (process.env.GITHUB_TOKEN) headers.Authorization = `Bearer ${process.env.GITHUB_TOKEN}`;
  const res = await fetch(`https://api.github.com${path}`, { headers });
  if (!res.ok) throw new Error(`GET ${path} -> ${res.status} ${await res.text()}`);
  return res.json();
}

async function discover() {
  const repos = [];
  for (let page = 1; page <= 10; page++) {
    const batch = await gh(`/orgs/${ORG}/repos?per_page=100&type=public&page=${page}`);
    repos.push(...batch);
    if (batch.length < 100) break;
  }

  // The [YF Build] description prefix is the org-wide discovery filter — the same one the
  // daily Notion sync uses. The org also holds CAKE work and internal tooling.
  const tagged = repos
    .filter((r) => !r.archived && !r.fork && (r.description ?? "").startsWith("[YF Build]"))
    .map((r) => r.name)
    .sort();

  // Ask the live URL rather than the Pages API. The Pages API needs pages:read on each
  // individual repo, which a repo-scoped GITHUB_TOKEN does not have — and a 200 from the
  // actual URL is the thing the renderer needs anyway, so it is the better question.
  const live = [];
  for (const slug of tagged) {
    let ok = false;
    try {
      const res = await fetch(liveUrl(slug), { method: "GET", redirect: "follow" });
      ok = res.ok;
    } catch { /* network hiccup counts as not live */ }
    console.log(`  ${ok ? "live   " : "no page"}  ${slug}`);
    if (ok) live.push(slug);
  }
  return live;
}

// ---------------------------------------------------------------- ordering

// Preserve the order already in builds.txt and append new slugs at the end. The THUMBS
// block is injected in this same order, so reordering it would rewrite every data URI in
// the page and turn a one-build addition into a whole-file diff.
function orderSlugs(discovered) {
  const previous = existsSync(LIST_FILE)
    ? readFileSync(LIST_FILE, "utf8")
        .split(/\r?\n/)
        .map((l) => l.trim())
        .filter((l) => l && !l.startsWith("#"))
    : [];

  const onDisk = new Set(
    existsSync(SHOT_DIR)
      ? readdirSync(SHOT_DIR).filter((f) => f.endsWith(".jpg")).map((f) => f.slice(0, -4))
      : []
  );
  const found = new Set(discovered);

  // Keep a known slug if it is still discoverable, or if it still has an image. The second
  // clause is what stops a transient 404 during a Pages deploy from dropping a good tile.
  const kept = previous.filter((s) => found.has(s) || onDisk.has(s));
  const added = discovered.filter((s) => !previous.includes(s));

  // Supplied stills. A build that cannot be a live page — a hosted script, a service, an
  // asset pack — has no Pages URL, so discovery drops it and it can never reach `added`.
  // Without this clause it could not enter `order` at all, and `inject` only walks `order`:
  // committing thumbs/<slug>.jpg for such a build did NOTHING, silently, forever. That is
  // the same shape as the builds.txt failure above — a documented step with no code behind
  // it. Only slugs that ALREADY have an image qualify, so this can never push a slug into
  // `toRender` and send headless Chrome at a URL that 404s.
  const supplied = [...onDisk]
    .filter((s) => !previous.includes(s) && !found.has(s))
    .sort();

  return { order: [...kept, ...added, ...supplied], added, supplied, onDisk };
}

// ---------------------------------------------------------------- render

async function render(browser, slug) {
  const page = await browser.newPage();
  try {
    await page.setViewport({ width: 1280, height: 800, deviceScaleFactor: 1 });
    await page.goto(liveUrl(slug), { waitUntil: "networkidle2", timeout: 60_000 });
    // Let animation, web fonts and WebGL settle. networkidle2 fires well before a
    // canvas-heavy build has drawn anything worth looking at.
    await new Promise((r) => setTimeout(r, 4500));
    const png = await page.screenshot({ type: "png", fullPage: false });
    const jpg = await sharp(png)
      .resize(WIDTH, HEIGHT, { fit: "fill", kernel: "lanczos3" })
      .jpeg({ quality: QUALITY })
      .toBuffer();
    writeFileSync(jpgPath(slug), jpg);
    console.log(`  rendered  ${slug.padEnd(34)} ${jpg.length.toLocaleString()} bytes`);
    return true;
  } catch (err) {
    // A failed render must cost a stale image, never a good one. Leave whatever is on disk
    // alone and carry on — the injection step reads from disk, not from this run.
    console.log(`  FAILED    ${slug} — ${err.message.split("\n")[0]}`);
    return false;
  } finally {
    await page.close().catch(() => {});
  }
}

// ---------------------------------------------------------------- inject

// Inject from DISK, not from what rendered this run. A run where some captures failed used
// to replace the whole THUMBS map with only its successes, silently deleting working
// thumbnails — six of fourteen renders failed on 2026-08-21 and wiped five good images.
//
// Keying: a live build is keyed by its Pages URL, a build without one by its bare repo
// slug. The dashboard's thumbFor() tries slug first and Live URL second, so both resolve —
// but keying a build that has no Pages URL by liveUrl() produces a 404 string that no card
// ever looks up, which is the second reason a supplied still stayed invisible. Pass `live`
// so this decision is explicit rather than reaching for module state.
function inject(order, { dryRun = false, live = new Set() } = {}) {
  const entries = [];
  const missing = [];
  for (const slug of order) {
    if (!existsSync(jpgPath(slug))) { missing.push(slug); continue; }
    const b64 = readFileSync(jpgPath(slug)).toString("base64");
    const key = live.has(slug) ? liveUrl(slug) : slug;
    entries.push(`"${key}":"data:image/jpeg;base64,${b64}"`);
  }
  if (entries.length === 0) throw new Error(`No thumbnails on disk — refusing to touch ${HTML}`);

  const before = readFileSync(HTML, "utf8");
  const pattern = /var THUMBS = \{[\s\S]*?\};/;
  if (!pattern.test(before)) throw new Error(`Could not find the THUMBS block in ${HTML}`);
  const after = before.replace(pattern, () => `var THUMBS = {${entries.join(",\n")}};`);
  if (after !== before && !dryRun) writeFileSync(HTML, after, "utf8");

  return { count: entries.length, missing, changed: after !== before };
}

function writeList(order) {
  const header = [
    "# GENERATED FILE — do not edit by hand.",
    "#",
    "# tools/render-thumbnails.mjs rewrites this every run. It is a RECORD of which builds",
    "# were tiled, not the list that decides. The list is derived from GitHub: every repo in",
    "# the yfagency org whose description starts with [YF Build] and whose Pages URL answers",
    "# 200 — plus any build that has a supplied still in thumbs/<slug>.jpg but no Pages URL,",
    "# which is how a build that cannot be a live page (a hosted script, a service, an asset",
    "# pack) gets a tile. Adding a slug here does nothing; removing one does nothing.",
    "#",
    "# It used to be the input, and that is exactly how yf-operating-model-visualization and",
    "# yf-brand-os-visuals both shipped with hazard tiles — published correctly, registered",
    "# correctly, and never added to a file only two people could push.",
    "",
  ].join("\n");
  writeFileSync(LIST_FILE, header + order.join("\n") + "\n", "utf8");
}

// ---------------------------------------------------------------- main

console.log(`discovering [YF Build] repos in ${ORG}/`);
const discovered = await discover();
if (discovered.length === 0) throw new Error("Discovery found no live builds — aborting rather than emptying the page.");

const { order, added, supplied, onDisk } = orderSlugs(discovered);
const LIVE = new Set(discovered);
if (supplied.length) console.log(`supplied stills (no live page): ${supplied.join(", ")}`);
console.log(`\n${order.length} builds tracked, ${added.length} new: ${added.join(", ") || "none"}`);

const toRender = forceAll
  ? order
  : order.filter((s) => !onDisk.has(s) || forceList.includes(s));

// PLAN pass: say what a real run would do, write nothing, and import nothing heavy. The
// workflow runs this on every scheduled tick and only installs the renderer when it says
// there is work. That is what makes a 2-hourly schedule cheap enough to be the primary
// path, so nobody needs a manual trigger they may not have permission to pull.
if (process.env.PLAN_ONLY) {
  const plan = inject(order, { dryRun: true, live: LIVE });
  const work = toRender.length > 0 || plan.changed;
  console.log(`\nplan: render [${toRender.join(", ") || "nothing"}], page ${plan.changed ? "would change" : "already current"}`);
  if (process.env.GITHUB_OUTPUT) {
    writeFileSync(
      process.env.GITHUB_OUTPUT,
      [`work=${work ? "true" : "false"}`, `needed=${toRender.join(" ")}`, ""].join("\n"),
      { flag: "a" }
    );
  }
  process.exit(0);
}

if (toRender.length) {
  mkdirSync(SHOT_DIR, { recursive: true });
  console.log(`\nrendering ${toRender.length}: ${toRender.join(", ")}`);
  const { default: puppeteer } = await import("puppeteer");
  sharp = (await import("sharp")).default;
  const browser = await puppeteer.launch({
    headless: true,
    args: [
      "--no-sandbox",
      "--disable-dev-shm-usage",
      "--disable-gpu",
      // Headless has no real GL. Without a software implementation the canvas- and
      // WebGL-heavy builds capture as solid black.
      "--enable-unsafe-swiftshader",
      "--hide-scrollbars",
      "--font-render-hinting=none",
    ],
  });
  try {
    for (const slug of toRender) await render(browser, slug);
  } finally {
    await browser.close();
  }
} else {
  console.log("\nnothing to render — every tracked build already has an image");
}

writeList(order);
const { count, missing, changed } = inject(order, { live: LIVE });
console.log(`\ninjected ${count} thumbnails into ${HTML}${changed ? "" : " (no change)"}`);

// A supplied still is not an orphan — it is in `order` deliberately and is the only route
// onto the dashboard for a build with no Pages URL. Flag only images nothing tracks.
const orphans = [...onDisk].filter((s) => !discovered.includes(s) && !order.includes(s));
if (orphans.length) console.log(`orphaned images (no live build): ${orphans.join(", ")}`);
if (missing.length) console.log(`STILL MISSING: ${missing.join(", ")}`);

if (process.env.GITHUB_OUTPUT) {
  writeFileSync(
    process.env.GITHUB_OUTPUT,
    [
      `missing=${missing.join(" ")}`,
      `missing_count=${missing.length}`,
      `added=${added.join(" ")}`,
      `changed=${changed ? "true" : "false"}`,
      "",
    ].join("\n"),
    { flag: "a" }
  );
}
