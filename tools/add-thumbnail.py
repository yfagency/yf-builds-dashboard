"""Add or refresh ONE build's thumbnail, without re-rendering the others.

    python tools/add-thumbnail.py yf-grid-specimen

Why this exists alongside refresh-thumbnails.ps1
------------------------------------------------
Two independent reasons.

1. Chrome's --screenshot flag writes nothing under the Claude Code sandbox. Chrome
   itself runs fine there and has network (--dump-dom works), but the file write is
   blocked, so every build reports "did not render - skipped" and the PowerShell
   script correctly aborts without touching the HTML. This script drives Chrome over
   the DevTools protocol instead: CDP returns the image as base64 over the wire and
   Python does the writing, which the sandbox permits. Verified 2026-08-20, ZF-Laptop,
   Chrome 151.

2. Adding one build should not require re-rendering the other six. The PowerShell
   script rewrites the whole THUMBS block, so a single addition churns every data URI
   in the page. This one inserts a single entry and leaves the rest byte-for-byte.

refresh-thumbnails.ps1 is still the right tool for a full refresh on a machine where
Chrome can write files. Keep the $builds list in it current either way.

Needs: pip install websocket-client pillow
"""
import base64, io, json, os, re, subprocess, sys, tempfile, time, uuid
import urllib.parse, urllib.request
import websocket
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
HTML = os.path.join(ROOT, "yf-builds-dashboard.artifact.html")
THUMBS = os.path.join(ROOT, "thumbs")

CHROME_CANDIDATES = [
    r"C:\Program Files\Google\Chrome\Application\chrome.exe",
    r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
    r"C:\Program Files\Microsoft\Edge\Application\msedge.exe",
]
PORT = 9333
VIEW_W, VIEW_H = 1280, 800
OUT_W, OUT_H = 640, 400
QUALITY = 62          # matches the JPEGs the PowerShell script produces
SETTLE_SECONDS = 6    # webfonts, canvas, any entry animation


def capture(url, out_jpg):
    chrome = next((c for c in CHROME_CANDIDATES if os.path.exists(c)), None)
    if not chrome:
        sys.exit("no Chromium browser found - install Chrome or Edge")

    profile = os.path.join(tempfile.gettempdir(), "cdp-" + uuid.uuid4().hex)
    proc = subprocess.Popen(
        [chrome, "--headless=new", "--disable-gpu", "--enable-unsafe-swiftshader",
         "--hide-scrollbars", "--no-first-run", "--no-default-browser-check",
         f"--user-data-dir={profile}", f"--remote-debugging-port={PORT}",
         # without this the CDP websocket handshake is refused with 403
         "--remote-allow-origins=*",
         f"--window-size={VIEW_W},{VIEW_H}", "about:blank"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def http(path, method="GET"):
        req = urllib.request.Request(f"http://127.0.0.1:{PORT}{path}", method=method)
        return json.loads(urllib.request.urlopen(req, timeout=5).read())

    try:
        for _ in range(60):
            try:
                ver = http("/json/version")
                break
            except Exception:
                time.sleep(0.5)
        else:
            sys.exit("CDP endpoint never came up")
        print("  browser:", ver.get("Browser"))

        tab = http("/json/new?" + urllib.parse.quote(url, safe=":/?=&"), method="PUT")
        ws = websocket.create_connection(tab["webSocketDebuggerUrl"], timeout=60)

        state = {"n": 0}

        def send(method, params=None):
            state["n"] += 1
            me = state["n"]
            ws.send(json.dumps({"id": me, "method": method, "params": params or {}}))
            while True:
                msg = json.loads(ws.recv())
                if msg.get("id") == me:
                    if "error" in msg:
                        raise RuntimeError(f"{method}: {msg['error']}")
                    return msg.get("result", {})

        send("Page.enable")
        send("Emulation.setDeviceMetricsOverride",
             {"width": VIEW_W, "height": VIEW_H, "deviceScaleFactor": 1, "mobile": False})
        send("Page.navigate", {"url": url})
        time.sleep(SETTLE_SECONDS)

        probe = send("Runtime.evaluate",
                     {"expression": "document.fonts.status + '|' + document.title",
                      "returnByValue": True})
        print("  page:", probe["result"]["value"])

        shot = send("Page.captureScreenshot", {"format": "png", "captureBeyondViewport": False})
        raw = base64.b64decode(shot["data"])
        im = Image.open(io.BytesIO(raw)).convert("RGB")

        # A wholly black frame means the render failed - usually GL. Better to fail
        # loudly than to bake a black tile into the dashboard.
        if max(im.convert("L").getextrema()) < 8:
            sys.exit("  captured frame is entirely black - refusing to use it")

        im.resize((OUT_W, OUT_H), Image.LANCZOS).save(
            out_jpg, "JPEG", quality=QUALITY, optimize=True)
        print("  wrote:", out_jpg, os.path.getsize(out_jpg), "bytes")
        ws.close()
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=10)
        except Exception:
            proc.kill()


def inject(url, jpg):
    b64 = base64.b64encode(open(jpg, "rb").read()).decode("ascii")
    entry = f'"{url}":"data:image/jpeg;base64,{b64}"'

    with io.open(HTML, encoding="utf-8", newline="") as fh:
        s = fh.read()

    m = re.search(r"var THUMBS = \{(.*?)\};", s, re.S)
    if not m:
        sys.exit("could not find the THUMBS block")
    body = m.group(1)

    key = re.compile(r'"' + re.escape(url) + r'"\s*:\s*"data:image/jpeg;base64,[^"]*"')
    if key.search(body):
        new_body = key.sub(entry, body)          # refresh in place
        action = "replaced"
    else:
        stripped = body.rstrip()
        new_body = stripped + (",\n" if stripped else "") + entry
        action = "added"

    s = s[: m.start()] + "var THUMBS = {" + new_body + "};" + s[m.end():]
    with io.open(HTML, "w", encoding="utf-8", newline="") as fh:
        fh.write(s)

    after = re.search(r"var THUMBS = \{(.*?)\};", s, re.S).group(1)
    n = len(re.findall(r'"https://yfagency\.github\.io/[a-z0-9-]+/"\s*:', after))
    print(f"  {action} {url} - {n} thumbnails now in the page")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    slug = sys.argv[1]
    live = f"https://yfagency.github.io/{slug}/"
    os.makedirs(THUMBS, exist_ok=True)
    jpg = os.path.join(THUMBS, f"{slug}.jpg")
    print(slug)
    capture(live, jpg)
    inject(live, jpg)
    print("\nNow republish the artifact so the team sees it:")
    print("  same URL, favicon is the hammer and wrench U+1F6E0 - settled, never substitute")
