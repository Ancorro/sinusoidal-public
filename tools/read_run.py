"""Prints a run log (user://runs/*.jsonl) as a readable transcript.

python tools/read_run.py              latest log
python tools/read_run.py FILE         that log
python tools/read_run.py --list       the 15 latest logs
Options: --events (also show raw rule events), --battle=N (only battle N), --options (list the Dealer's options)
"""
import json
import os
import sys
from pathlib import Path

RUNS = Path(os.environ.get("APPDATA", Path.home())) / "Godot" / "app_userdata" / "Sinusoidal" / "runs"


def logs():
    return sorted(RUNS.glob("*.jsonl"), key=lambda p: p.stat().st_mtime)


def fmt(d, flags):
    t, k = d["t_ms"], d["type"]
    turn = f"T{d['turn']:<3}" if "turn" in d else "    "
    pre = f"{t / 1000:7.2f}s {turn} "
    if k == "run_start":
        meta = {x: y for x, y in d.items() if x not in ("type", "t_ms", "map")}
        if "map" in d:
            meta["map"] = " ".join(f"{n['row']}:{n['type']}" for n in d["map"])
        return pre + "RUN START " + json.dumps(meta)
    if k == "stop":
        rest = {x: y for x, y in d.items() if x not in ("type", "t_ms", "index", "kind", "deck")}
        if "deck" in d:
            rest["deck"] = len(d["deck"])
        return pre + f"--- stop {d.get('index', '?')}: {d.get('kind', '?')} " + json.dumps(rest)
    if k == "battle_start":
        return (f"\n{pre}=== BATTLE {d['battle']}  seed {d['seed']}"
                + (f"  player bot {d['player_bot']} vs brain {d['brain']}" if "player_bot" in d else "")
                + ("  BOSS" if d.get("boss") else "")
                + (f"  starts scale {d['scale']}" if d.get("scale") else "")
                + (f"  bones {d['bones']}" if any((d.get("bones") or {}).values()) else "")
                + f"\n{' ' * 13}player hand {', '.join(d['player_hand'])}\n{' ' * 13}dealer hand {', '.join(d['dealer_hand'])}")
    if k == "log":
        return pre + "  " + d["text"]
    if k == "play":
        return None  # the battle's own log line says the same
    if k == "dealer_move":
        tries = f", {d['attempts']} tries" if d.get("attempts", 1) > 1 else ""
        out = pre + f"  Dealer ({d['ms']} ms, {d['n_options']} options{tries}) -> {d['picked']}"
        if not d.get("legal", True):
            out += "  [ILLEGAL]"
        if d.get("say"):
            out += f'\n{" " * 15}"{d["say"]}"'
        if "--options" in flags:
            out += "".join(f"\n{' ' * 17}{i}. {o}" for i, o in enumerate(d["options"]))
        return out
    if k == "say":
        return pre + f'  You: "{d["text"]}"\n{" " * 15}Dealer ({d["ms"]} ms): "{d["reply"]}"'
    if k in ("cut", "restore"):
        return pre + f"  WIRE {d['wire']} {k.upper()}"
    if k == "choice":
        return pre + f"  choice {d['options']} -> {d['picked']}"
    if k == "event_stop":
        return pre + f"  event: {json.dumps(d.get('history', []))}"
    if k == "battle_end":
        return pre + f"=== END battle {d['battle']}: {d['winner'] or 'unfinished'} wins, {d['turns']} turns, scale {d['scale']}" + (
            f", {d['ms']} ms" if "ms" in d else "")
    if k == "run_end":
        return pre + "RUN END " + json.dumps({x: y for x, y in d.items() if x not in ("type", "t_ms")})
    if k == "error":
        return pre + f"  !! ERROR {d['what']}" + (f" (seed {d['seed']})" if "seed" in d else "")
    if k == "event":
        return pre + "  . " + json.dumps({x: y for x, y in d.items() if x not in ("type", "t_ms", "turn")}) if "--events" in flags else None
    return pre + json.dumps(d)


def main():
    flags = [a for a in sys.argv[1:] if a.startswith("--")]
    files = [a for a in sys.argv[1:] if not a.startswith("--")]
    if "--list" in flags:
        for p in logs()[-15:]:
            print(f"{p.stat().st_size:>9}  {p}")
        return
    path = Path(files[0]) if files else (logs() or [None])[-1]
    if path is None:
        sys.exit(f"no logs in {RUNS}")
    only = next((int(f.split("=")[1]) for f in flags if f.startswith("--battle=")), None)
    print(f"# {path}")
    battle = 0
    for raw in path.open(encoding="utf-8"):
        try:
            d = json.loads(raw)
        except json.JSONDecodeError:
            print("   (unreadable line; the game may have crashed mid-write)")
            continue
        if d["type"] == "battle_start":
            battle = d["battle"]
        if only is not None and battle != only and d["type"] not in ("run_start", "run_end"):
            continue
        line = fmt(d, flags)
        if line is not None:
            print(line)


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8")
    try:
        main()
    except (BrokenPipeError, OSError):   # output piped into head and closed
        pass
