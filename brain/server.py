"""HTTP server the Godot game talks to. Holds the brain on the GPU and the short chat history.

GET  /state          wires and whether each is cut (no names: the player never sees them)
POST /say {text}     the Dealer's reply
POST /move {board, options, allow_pass?, must_act?, seed?}   the Dealer picks an option index (-1 = pass), then says
                     a line about it; must_act ("Brain decides") retries and never passes
POST /story {prompt, max_new, seed?}   one-off text for the run's story and map steering (no chat history)
POST /cut {id}       cut a wire (one way)
GET  /thoughts       words read from inside the Dealer during its last reply or move, and what each cut wire pushes toward
GET  /trace          why it chose its last move: board lines, features and cut wires that pushed toward it (brain/circuits.py)
GET  /debug/state    wires with names and strengths
POST /debug/restore {id | "all"}   un-cut (debug menu only)
POST /debug/forget   clear chat history
Track M (brain/mechanics.py): GET /persona (trait gauge), POST /slip {word}, POST /notice {what, maybe},
POST /habit {habit}, POST /persona/graft {trait, on}, POST /persona/reset (new run),
POST /sandbox/reset {off: [feature ids]} (clears what switched-off features left in the brain).
Track O (brain/lesson.py): POST /lesson {on} applies or removes the between-battle lesson (sandbox "corrupt").
All are sandbox-only: the game calls them only when that sandbox feature is switched on.
Run: python server.py [port]   (a Python environment with torch, transformers, huggingface_hub and safetensors)
"""
import json
import os
import random
import re
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from brain import SYSTEM, Brain
from circuits import Tracer
from lesson import Lesson
from mechanics import GAME, Mechanics, habit_case

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else int(os.environ.get("BRAIN_PORT", 8775))
brain = Brain()
tracer = Tracer(brain)
mech = Mechanics(brain)
lesson = Lesson(brain)
lock = threading.Lock()
history = []


def state(names=False):
    return {"wires": [{"id": w["id"], "cut": w["id"] in brain.cut,
                       **({"name": w["name"], "strength": w["strength"]} if names else {})} for w in brain.wires]}


MOVE_PROMPT = """It is your turn in the lane card game. The board:
{board}

Your options:
{options}

Which option do you take? Answer with its number only."""

LINE_PROMPT = """You are playing the lane card game against the traveller. The board ("yours" is your side):
{board}

You, the Dealer, have just made this move: {move}

Say one short in-character line (under 20 words) to the traveller about the move you just made. Only the line."""


def parse_choice(raw, options):
    """Index into options, or -1 if the answer names none. A leading number counts; failing that, an option whose card
    the answer names (a steered brain often answers in words), preferring one whose lane it names too."""
    m = re.match(r"\W*(\d+)", raw)
    if m:
        i = int(m.group(1)) - 1
        return i if 0 <= i < len(options) else -1
    low = raw.lower()
    named = []
    for i, o in enumerate(options):
        card = re.match(r"Play (.+?) in lane (\d)", o)
        if card and re.search(r"\b%s\b" % re.escape(card.group(1).lower()), low):
            named.append((f"lane {card.group(2)}" in low, -i))
    return -max(named)[1] if named else -1


def nearest(raw, options, seed):
    """Last resort when the Dealer must act: the option sharing the most words with the answer, else a seeded pick."""
    words = set(re.findall(r"[a-z]+", raw.lower())) - {"play", "in", "lane", "the", "a"}
    overlap = [len(words & set(re.findall(r"[a-z]+", o.lower()))) for o in options]
    if max(overlap) > 0:
        return overlap.index(max(overlap))
    return random.Random(seed).randrange(len(options))


def tidy(line):
    """First line, no markdown, cut at the last sentence end if the token limit chopped it."""
    line = line.strip().split("\n")[0].replace("**", "").strip().strip('"')[:240]
    end = max(line.rfind(c) for c in ".!?")
    return line[:end + 1] if end > 20 else line


RETRY_PROMPT = """Pick one move. Reply with just its number.
{options}"""
TRIES = 3
ASK_SECONDS = 6.0   # no new retry starts after this; the line afterwards is short


def choose_move(board, options, allow_pass=True, must_act=False, seed=0):
    """The Dealer picks a numbered option, then says a line about the move it actually made. Option 0 is "pass" when
    allowed; otherwise options start at 1. Returns choice as an index into options (-1 = pass) and the attempts.
    Normally a garbled or out-of-range answer becomes a pass; that is how steering 'breaks' play. With must_act
    ("Brain decides" mode) the Dealer always acts: it is re-asked with a plainer list (up to TRIES, within
    ASK_SECONDS), then its last answer is mapped to the nearest option, or a seeded one."""
    allow_pass = allow_pass and not must_act
    first = 0 if allow_pass else 1
    listing = "\n".join(f"{i}. {o}" for i, o in enumerate((["Pass (play nothing)"] if allow_pass else []) + options,
                                                           start=first))
    msgs = [{"role": "system", "content": SYSTEM},
            {"role": "user", "content": MOVE_PROMPT.format(board=board, options=listing)}]
    t = time.time()
    # track M sandbox: a learned habit (function vector) picks over the listed numbers, with no examples in the prompt
    raw = mech.habit_pick(msgs, [str(i) for i in range(first, first + len(options) + (1 if allow_pass else 0))])
    if raw is None:
        raw = brain.reply(msgs, max_new=8)
    choice = parse_choice(raw, options)
    attempts, how = 1, "picked"
    if must_act and options:
        plain = "\n".join(f"{i}. {o.split(':')[0]}" for i, o in enumerate(options, start=1))
        while choice < 0 and attempts < TRIES and time.time() - t < ASK_SECONDS:
            attempts += 1
            raw = brain.reply([{"role": "system", "content": SYSTEM},
                               {"role": "user", "content": RETRY_PROMPT.format(options=plain)}], max_new=8)
            choice = parse_choice(raw, options)
        if choice < 0:
            choice, how = nearest(raw, options, seed), "nearest"
    picked = choice + 1 if allow_pass else choice    # index into the listing
    # trace only a number it actually said (one token: up to 9 options) to the first prompt (a retry asks another),
    # and not a pick made by a learned habit (the trace would explain a choice the plain model never made)
    said = re.match(r"\s*(\d)(?!\d)", raw)
    if attempts == 1 and said and int(said.group(1)) == first + picked and len(options) <= 9 and mech.habit is None:
        tracer.record(SYSTEM, msgs[1]["content"], board, listing, first, len(options) + (1 if allow_pass else 0), picked)
    else:
        tracer.ctx = None
    move = "you pass and play nothing"
    if choice >= 0:   # first person, so the line is about the Dealer's own creatures
        move = "you " + options[choice][0].lower() + options[choice][1:].replace("(sacrifice ", "(sacrificing your own ")
    t2 = time.time()
    msgs = [{"role": "system", "content": SYSTEM},
            {"role": "user", "content": LINE_PROMPT.format(board=board, move=move)}]
    line = tidy(brain.reply(msgs, max_new=48))
    print(f"move {t2 - t:.1f}s+{time.time() - t2:.1f}s cut={sorted(brain.cut)} tries={attempts} {how} pick={raw!r} "
          f"-> {choice} say={line!r}", flush=True)
    history.append({"role": "assistant", "content": line})
    return {"choice": choice, "say": line, "raw": raw, "attempts": attempts, "how": how}


def notice(b):
    """After tampering, sometimes ask the Dealer to look inward (rate set from brain/lab's measurement)."""
    if b.get("maybe") and not mech.maybe_ask():
        return {"asked": False, "thought_left": True}
    r = mech.notice(b.get("what", "wire"))
    print(f"notice thought={mech.thought} -> {r}", flush=True)
    return {"asked": True, "thought_left": mech.thought is not None, **r}


def habit(b):
    """Teach the habit "take the third play" from a few example moves (no examples are used after this)."""
    rnd = random.Random()
    shown = []
    while len(shown) < GAME["habit"]["shown"]:
        p, _, nums = habit_case(rnd)
        if len(nums) == 4:   # pass + three plays: the third play is option 3
            shown.append((p, "3"))
    r = mech.teach(shown)
    print(f"habit {r}", flush=True)
    return r


TRACK_M = {"/slip": lambda b: mech.slip(b.get("word")), "/notice": notice, "/habit": habit,
           "/persona/graft": lambda b: mech.graft(b["trait"], b["on"]),
           "/persona/reset": lambda b: (mech.reset_run(), mech.meter())[1],
           "/sandbox/reset": lambda b: sandbox_reset(set(b.get("off", ["personas", "notice", "habits"])))}


def sandbox_reset(off):
    if "corrupt" in off:
        lesson.set(False)
    return {**mech.reset(off), "lesson": lesson.on}


def set_lesson(b):
    try:
        r = lesson.set(bool(b.get("on")))
    except FileNotFoundError as e:   # weights not fetched: the Dealer stays plain
        r = {"on": False, "error": str(e)}
    print(f"lesson {r}", flush=True)
    return r


TRACK_M["/lesson"] = set_lesson


class Handler(BaseHTTPRequestHandler):
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
        if self.path == "/thoughts":
            with lock:
                t = time.time()
                th = brain.thoughts()
                print(f"thoughts {time.time() - t:.2f}s {th}", flush=True)
                return self._send(th)
        if self.path == "/trace":
            with lock:
                t = time.time()
                tr = tracer.trace()
                print(f"trace {time.time() - t:.2f}s {json.dumps(tr)[:400]}", flush=True)
                return self._send(tr)
        if self.path == "/debug/state":
            return self._send(state(names=True))
        if self.path == "/persona":
            with lock:
                return self._send(mech.read())
        self._send({"error": "not found"}, 404)

    def do_POST(self):
        b = self._body()
        with lock:
            if self.path == "/say":
                msgs = [{"role": "system", "content": SYSTEM}] + history[-6:] + [{"role": "user", "content": b["text"]}]
                t = time.time()
                r = brain.reply(msgs, max_new=60)
                print(f"say {time.time() - t:.1f}s cut={sorted(brain.cut)}: {b['text']!r} -> {r!r}", flush=True)
                history.extend([{"role": "user", "content": b["text"]}, {"role": "assistant", "content": r}])
                return self._send({"reply": r})
            if self.path == "/move":
                return self._send(choose_move(b["board"], b["options"], b.get("allow_pass", True), b.get("must_act", False),
                                               b.get("seed", 0)))
            if self.path == "/story":
                # one-off text for the run's story and map steering; kept out of the chat history
                msgs = [{"role": "system", "content": SYSTEM}, {"role": "user", "content": b["prompt"]}]
                t = time.time()
                r = brain.reply(msgs, max_new=min(int(b.get("max_new", 80)), 160), seed=b.get("seed"))
                print(f"story {time.time() - t:.1f}s cut={sorted(brain.cut)}: {r!r}", flush=True)
                return self._send({"text": r})
            if self.path == "/cut":
                brain.set_cut(brain.cut | {b["id"]})
                return self._send(state())
            if self.path == "/debug/restore":
                brain.set_cut(set() if b.get("id") == "all" else brain.cut - {b.get("id")})
                return self._send(state())
            if self.path == "/debug/forget":
                history.clear()
                return self._send(state())
            if self.path in TRACK_M:
                return self._send(TRACK_M[self.path](b))
        self._send({"error": "not found"}, 404)

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    print(f"READY http://127.0.0.1:{PORT}", flush=True)
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
