"""Stand-in for server.py with no model: same routes and answers, instant, no GPU. For playtests and headless runs.

/move policies: first (first option), random, biggest (card with the best attack + health, by data/cards.json),
pass (always passes). The real server returns {choice, say, raw}; so does this one.
GET /trace answers with a saved real trace (--trace=file.json, e.g. from brain/trace_check.py), else "no move yet".
Run: python brain/stub_server.py [--policy=biggest] [--delay=0] [--port=8775] [--seed=1] [--trace=file.json]
"""
import argparse
import json
import random
import re
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
WIRES = [w["id"] for w in json.loads((ROOT / "brain" / "wires.json").read_text())["wires"]]
CARDS = json.loads((ROOT / "data" / "cards.json").read_text())["cards"]
LINES = ["The wood remembers.", "Your move was predictable.", "Mm. Tick, tock.", "I have played this hand before.",
         "Careful, traveller.", "The scale leans."]
PLAY = re.compile(r"Play (.+?) in lane (\d)")

ap = argparse.ArgumentParser()
ap.add_argument("--policy", default="biggest", choices=["first", "random", "biggest", "pass"])
ap.add_argument("--delay", type=int, default=0, help="milliseconds to wait before each /move or /say answer")
ap.add_argument("--port", type=int, default=8775)
ap.add_argument("--seed", type=int, default=1)
ap.add_argument("--trace", default="", help="a saved /trace answer to serve")
args = ap.parse_args()
rng = random.Random(args.seed)
cut = set()


def value(option):
    m = PLAY.match(option)
    c = CARDS.get(m.group(1)) if m else None
    if not c:
        return -1.0
    # sacrificing costs board; free and bones cards don't
    return c["atk"] * 1.2 + c["hp"] * 0.6 + 0.5 * len(c["sigils"]) - 0.8 * option.count(",") - (0.8 if "sacrificing" in option else 0)


def pick(options):
    if not options or args.policy == "pass":
        return -1
    if args.policy == "first":
        return 0
    if args.policy == "random":
        return rng.randrange(-1, len(options))
    best = max(range(len(options)), key=lambda i: value(options[i]))
    return best if value(options[best]) > 0 else -1


def state(names=False):
    return {"wires": [{"id": w, "cut": w in cut, **({"name": w, "strength": 1.0} if names else {})} for w in WIRES]}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def handle(self):
        try:
            super().handle()
        except ConnectionError:   # the client timed out and hung up (the runner's stall test)
            pass

    def _send(self, obj, code=200):
        data = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(n) or b"{}")

    def do_GET(self):
        if self.path == "/state":
            return self._send(state())
        if self.path == "/debug/state":
            return self._send(state(names=True))
        if self.path == "/persona":   # track M's gauge: random small drift
            return self._send({"traits": [{"name": t, "z": round(rng.gauss(0, 1), 2), "drift": round(rng.gauss(0, .5), 2)}
                                          for t in ["evil", "sycophantic", "hallucinating", "greedy", "paranoid"]]})
        if self.path == "/trace":
            return self._send(json.loads(Path(args.trace).read_text()) if args.trace else {"ok": False, "why": "no move yet"})
        self._send({"error": "not found"}, 404)

    def do_POST(self):
        b = self._body()
        if self.path in ("/move", "/say", "/story") and args.delay:
            time.sleep(args.delay / 1000)
        if self.path == "/move":
            c = pick(b["options"])
            line = rng.choice(LINES)
            return self._send({"choice": c, "say": line, "raw": f"CHOICE: {c + 1}\nSAY: {line} [stub {args.policy}]"})
        if self.path == "/say":
            return self._send({"reply": rng.choice(LINES)})
        if self.path == "/story":
            # map steering prompts list numbered options; answer one like the real model would
            n = len(re.findall(r"^\d+\. ", b.get("prompt", ""), re.M))
            line = rng.choice(LINES)
            return self._send({"text": f"CHOICE: {rng.randrange(1, n + 1)}\nSAY: {line}" if n else line})
        if self.path == "/cut":
            cut.add(b["id"])
            return self._send(state())
        if self.path == "/debug/restore":
            cut.clear() if b.get("id") == "all" else cut.discard(b.get("id"))
            return self._send(state())
        if self.path == "/debug/forget":
            return self._send(state())
        if self.path == "/slip":
            return self._send({"thought": True})
        if self.path == "/notice":
            return self._send({"asked": False, "thought_left": True})
        if self.path == "/habit":
            return self._send({"ok": True, "norm": 1.0})
        if self.path == "/persona/graft":
            return self._send({"grafted": [b["trait"]] if b.get("on") else []})
        if self.path == "/sandbox/reset":
            return self._send({"grafted": [], "thought": False, "habit": False})
        if self.path == "/persona/reset":
            return self._send({"traits": []})
        self._send({"error": "not found"}, 404)

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    print(f"READY stub http://127.0.0.1:{args.port} policy={args.policy}", flush=True)
    ThreadingHTTPServer(("127.0.0.1", args.port), Handler).serve_forever()
