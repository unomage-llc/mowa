#!/usr/bin/env python3
"""Review page for saved dev recordings: play each one, see what Mowa heard and typed, then
Accept (typed is right), Fix (type the right text), Nothing (nothing should be typed) or
Ignore (leave it out of the eval). Answers are written to <recording>/expected.txt, which
REAL=1 bash scripts/eval.sh picks up.

Usage: python3 scripts/label-server.py [recordings dir]   → opens http://127.0.0.1:8765
Runs only on this Mac (127.0.0.1); Ctrl+C stops it.
"""
import json, os, re, sys, threading, webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, unquote

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REC = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "build", "dev-recordings"))
PORT = 8765
NAME = re.compile(r"^[A-Za-z0-9_.-]+$")


def folder(name):
    if not NAME.match(name or "") or name in (".", ".."):
        return None
    path = os.path.join(REC, name)
    return path if os.path.isfile(os.path.join(path, "audio.wav")) else None


def read(path, default=""):
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except OSError:
        return default


def items():
    out = []
    if not os.path.isdir(REC):
        return out
    for name in sorted(os.listdir(REC), reverse=True):
        base = folder(name)
        if not base:
            continue
        try:
            meta = json.loads(read(os.path.join(base, "meta.json"), "{}"))
        except ValueError:
            meta = {}
        expected_path = os.path.join(base, "expected.txt")
        state, expected = "todo", None
        if os.path.exists(os.path.join(base, ".ignored")):
            state = "ignored"
        elif os.path.exists(expected_path):
            expected = read(expected_path).strip()
            typed = (meta.get("typed") or "").strip()
            state = "nothing" if expected == "" else ("accepted" if expected == typed else "fixed")
        out.append({
            "id": name, "state": state, "expected": expected,
            "date": meta.get("date", ""), "mode": meta.get("mode", ""),
            "language": meta.get("whisper_language", ""),
            "seconds": meta.get("audio_seconds", 0),
            "app": meta.get("start_app", ""),
            "heard": meta.get("whisper_text") or "",
            "typed": meta.get("typed") or "",
            "status": meta.get("status", ""), "error": meta.get("error", ""),
            "selection": meta.get("command_selection", ""),
        })
    return out


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send(self, code, body, ctype="application/json; charset=utf-8", extra=None):
        data = body if isinstance(body, bytes) else body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/":
            return self.send(200, PAGE, "text/html; charset=utf-8")
        if path == "/api/items":
            return self.send(200, json.dumps({"dir": REC, "items": items()}, ensure_ascii=False))
        if path.startswith("/audio/"):
            base = folder(unquote(path[len("/audio/"):]))
            if not base:
                return self.send(404, "{}")
            with open(os.path.join(base, "audio.wav"), "rb") as f:
                data = f.read()
            rng = self.headers.get("Range")
            m = re.match(r"bytes=(\d*)-(\d*)", rng or "")
            if m:
                start = int(m.group(1) or 0)
                end = int(m.group(2)) if m.group(2) else len(data) - 1
                end = min(end, len(data) - 1)
                return self.send(206, data[start:end + 1], "audio/wav", {
                    "Accept-Ranges": "bytes", "Content-Range": "bytes %d-%d/%d" % (start, end, len(data))})
            return self.send(200, data, "audio/wav", {"Accept-Ranges": "bytes"})
        self.send(404, "{}")

    do_HEAD = do_GET

    def do_POST(self):
        if urlparse(self.path).path != "/api/label":
            return self.send(404, "{}")
        if self.headers.get("Origin") not in (None, "http://127.0.0.1:%d" % PORT, "http://localhost:%d" % PORT):
            return self.send(403, "{}")
        try:
            body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        except ValueError:
            return self.send(400, "{}")
        base = folder(body.get("id"))
        if not base:
            return self.send(404, "{}")
        action = body.get("action")
        expected = os.path.join(base, "expected.txt")
        ignored = os.path.join(base, ".ignored")
        # Deleting is not allowed in some setups, so "undo" empties instead of removing.
        def clear(p):
            try:
                os.remove(p)
            except OSError:
                pass
        if action in ("accept", "fix", "nothing"):
            text = "" if action == "nothing" else str(body.get("text", ""))
            with open(expected, "w", encoding="utf-8") as f:
                f.write(text.strip() + "\n")
            clear(ignored)
        elif action == "ignore":
            open(ignored, "w").close()
            clear(expected)
        elif action == "reset":
            clear(expected)
            clear(ignored)
        else:
            return self.send(400, "{}")
        self.send(200, json.dumps({"ok": True}))


PAGE = r"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Mowa recordings</title>
<style>
:root{--bg:#f6f6f4;--card:#fff;--ink:#1d1d1f;--mute:#6e6e73;--line:#e3e3e0;--ok:#1f8a4c;--fix:#b26a00;--bad:#c4372f;--acc:#3a5bd9}
@media (prefers-color-scheme:dark){:root{--bg:#161617;--card:#212123;--ink:#f2f2f2;--mute:#9a9aa0;--line:#333336;--ok:#4cc27e;--fix:#e2a33b;--bad:#ef6b62;--acc:#7f9bff}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:15px/1.45 -apple-system,BlinkMacSystemFont,"SF Pro Text",sans-serif}
header{position:sticky;top:0;background:var(--bg);border-bottom:1px solid var(--line);padding:14px 20px;display:flex;gap:16px;align-items:center;flex-wrap:wrap;z-index:2}
h1{font-size:17px;margin:0}.count{color:var(--mute)}.tabs{display:flex;gap:6px;margin-left:auto}
.tabs button{border:1px solid var(--line);background:var(--card);color:var(--ink);border-radius:999px;padding:5px 12px;cursor:pointer;font:inherit;font-size:13px}
.tabs button.on{background:var(--ink);color:var(--bg);border-color:var(--ink)}
main{max-width:860px;margin:0 auto;padding:18px 20px 80px}
.card{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:16px 18px;margin-bottom:14px}
.card.cur{outline:2px solid var(--acc)}
.meta{display:flex;gap:10px;flex-wrap:wrap;color:var(--mute);font-size:12.5px;align-items:center}
.pill{border-radius:999px;padding:1px 9px;font-size:12px;font-weight:600}
.s-todo{background:#8882;color:var(--mute)}.s-accepted{background:#1f8a4c22;color:var(--ok)}.s-fixed{background:#b26a0022;color:var(--fix)}
.s-nothing{background:#3a5bd922;color:var(--acc)}.s-ignored{background:#c4372f1f;color:var(--bad)}
audio{width:100%;margin:10px 0 6px;height:36px}
.label{font-size:11.5px;text-transform:uppercase;letter-spacing:.05em;color:var(--mute);margin-top:10px}
.heard{color:var(--mute);white-space:pre-wrap}.typed{font-size:16px;white-space:pre-wrap}
textarea{width:100%;font:inherit;font-size:16px;padding:8px 10px;border:1px solid var(--line);border-radius:8px;background:var(--bg);color:var(--ink);min-height:64px;resize:vertical}
.actions{display:flex;gap:8px;flex-wrap:wrap;margin-top:12px}
.actions button{font:inherit;font-size:14px;border-radius:8px;padding:7px 14px;cursor:pointer;border:1px solid var(--line);background:var(--card);color:var(--ink)}
.actions .accept{background:var(--ok);border-color:var(--ok);color:#fff}.actions .save{background:var(--fix);border-color:var(--fix);color:#fff}
kbd{font:11px ui-monospace,monospace;border:1px solid var(--line);border-radius:4px;padding:0 4px;color:var(--mute);margin-left:4px}
.accept kbd,.save kbd{color:#fffd;border-color:#fff8}
.empty{color:var(--mute);text-align:center;padding:60px 0}.err{color:var(--bad)}
.help{color:var(--mute);font-size:12.5px;margin:0 0 14px}
</style></head><body>
<header><h1>Mowa recordings</h1><span class="count" id="count"></span>
<div class="tabs" id="tabs"></div></header>
<main><p class="help">Play, then: <b>Accept</b> if what Mowa typed is right, <b>Fix</b> to type what it should have written,
<b>Nothing</b> if nothing should have been typed, <b>Ignore</b> to leave it out of the tests.
Keys on the highlighted card: <kbd>Space</kbd> play · <kbd>A</kbd> accept · <kbd>F</kbd> fix · <kbd>N</kbd> nothing · <kbd>I</kbd> ignore · <kbd>J</kbd>/<kbd>K</kbd> next/previous.</p>
<div id="list"></div></main>
<script>
const TABS=[["todo","To do"],["done","Labelled"],["ignored","Ignored"],["all","All"]];
let tab="todo",items=[],cur=0,editing=null;
const $=s=>document.querySelector(s);
const esc=s=>String(s??"").replace(/[&<>"]/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c]));
const STATE={todo:"To do",accepted:"Accepted",fixed:"Fixed",nothing:"Nothing",ignored:"Ignored"};
function shown(){return items.filter(i=>tab=="all"||(tab=="todo"&&i.state=="todo")||(tab=="ignored"&&i.state=="ignored")||(tab=="done"&&!["todo","ignored"].includes(i.state)))}
async function load(){const r=await fetch("/api/items");const d=await r.json();items=d.items;render()}
function render(){
  const todo=items.filter(i=>i.state=="todo").length,done=items.filter(i=>!["todo","ignored"].includes(i.state)).length;
  $("#count").textContent=`${items.length} recordings · ${done} labelled · ${todo} to do`;
  $("#tabs").innerHTML=TABS.map(([k,l])=>`<button class="${k==tab?"on":""}" data-tab="${k}">${l}</button>`).join("");
  const list=shown(); if(cur>=list.length)cur=Math.max(0,list.length-1);
  if(!list.length){$("#list").innerHTML=`<div class="empty">${items.length?"Nothing here.":"No recordings yet — dictate with “Save recordings for testing” on."}</div>`;return}
  $("#list").innerHTML=list.map((i,n)=>{
    const d=i.date?new Date(i.date).toLocaleString():i.id;
    const fixing=editing==i.id;
    return `<div class="card ${n==cur?"cur":""}" data-n="${n}" data-id="${esc(i.id)}">
      <div class="meta"><span class="pill s-${i.state}">${STATE[i.state]}</span><span>${esc(d)}</span>
      <span>${Number(i.seconds||0).toFixed(1)} s</span>${i.language?`<span>${esc(i.language)}</span>`:""}
      ${i.mode&&i.mode!="dictation"?`<span>${esc(i.mode)}</span>`:""}${i.app?`<span>${esc(i.app)}</span>`:""}</div>
      <audio controls preload="none" src="/audio/${encodeURIComponent(i.id)}"></audio>
      ${i.selection?`<div class="label">Selected text (command)</div><div class="heard">${esc(i.selection)}</div>`:""}
      <div class="label">Heard</div><div class="heard">${esc(i.heard)||"—"}</div>
      <div class="label">Typed</div><div class="typed">${esc(i.typed)||"<span class=heard>(nothing)</span>"}</div>
      ${i.error?`<div class="err">${esc(i.error)}</div>`:""}
      ${i.state=="fixed"&&!fixing?`<div class="label">Should be</div><div class="typed">${esc(i.expected)}</div>`:""}
      ${fixing?`<div class="label">Should be</div><textarea id="fixtext">${esc(i.expected??i.typed)}</textarea>`:""}
      <div class="actions">${fixing?
        `<button class="save" data-act="save">Save<kbd>⌘↩</kbd></button><button data-act="cancel">Cancel<kbd>Esc</kbd></button>`:
        `<button class="accept" data-act="accept">Accept<kbd>A</kbd></button><button data-act="fix">Fix…<kbd>F</kbd></button>
         <button data-act="nothing">Nothing<kbd>N</kbd></button><button data-act="ignore">Ignore<kbd>I</kbd></button>
         ${i.state!="todo"?`<button data-act="reset">Undo</button>`:""}`}</div></div>`}).join("");
  if(editing){const t=$("#fixtext");if(t){t.focus();t.setSelectionRange(t.value.length,t.value.length)}}
}
async function act(id,action,text){
  const i=items.find(x=>x.id==id);if(!i)return;
  await fetch("/api/label",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({id,action,text:action=="accept"?i.typed:text})});
  editing=null;const keepTab=tab;await load();tab=keepTab;render();scrollCur();
}
function curItem(){return shown()[cur]}
function scrollCur(){const c=document.querySelector(".card.cur");if(c)c.scrollIntoView({block:"nearest",behavior:"smooth"})}
document.addEventListener("click",e=>{
  const t=e.target.closest("[data-tab]");if(t){tab=t.dataset.tab;cur=0;editing=null;render();return}
  const card=e.target.closest(".card");if(card){cur=+card.dataset.n}
  const b=e.target.closest("[data-act]");if(!b){if(card)render();return}
  const id=card.dataset.id,a=b.dataset.act;
  if(a=="fix"){editing=id;render()}else if(a=="cancel"){editing=null;render()}
  else if(a=="save"){act(id,"fix",$("#fixtext").value)}else act(id,a);
});
document.addEventListener("keydown",e=>{
  if(editing){if(e.key=="Escape"){editing=null;render()}else if(e.key=="Enter"&&(e.metaKey||e.ctrlKey)){e.preventDefault();act(editing,"fix",$("#fixtext").value)}return}
  if(e.target.tagName=="TEXTAREA"||e.metaKey||e.ctrlKey||e.altKey)return;
  const i=curItem();const k=e.key.toLowerCase();
  if(k=="j"||e.key=="ArrowDown"){cur=Math.min(cur+1,shown().length-1);render();scrollCur();e.preventDefault()}
  else if(k=="k"||e.key=="ArrowUp"){cur=Math.max(cur-1,0);render();scrollCur();e.preventDefault()}
  else if(!i)return;
  else if(e.key==" "){e.preventDefault();const a=document.querySelector(".card.cur audio");document.querySelectorAll("audio").forEach(x=>{if(x!==a)x.pause()});a.paused?a.play():a.pause()}
  else if(k=="a")act(i.id,"accept");else if(k=="n")act(i.id,"nothing");else if(k=="i")act(i.id,"ignore");
  else if(k=="f"){e.preventDefault();editing=i.id;render()}
});
document.addEventListener("play",e=>{document.querySelectorAll("audio").forEach(x=>{if(x!==e.target)x.pause()})},true);
load();
</script></body></html>"""

if __name__ == "__main__":
    if not os.path.isdir(REC):
        sys.exit("no recordings folder: %s\nbuild with --dev, turn on Settings → General → Save recordings for testing" % REC)
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    url = "http://127.0.0.1:%d" % PORT
    print("Mowa recordings: %s  (Ctrl+C to stop)" % url)
    threading.Timer(0.5, lambda: webbrowser.open(url)).start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
