"""Headless playtest batch: starts the stub brain (unless --brain is greedy/random), runs scripts/playtest.gd in Godot,
prints its report plus any engine errors Godot printed (GDScript errors don't stop a headless run, they only print).

python tools/playtest.py                        100 battles, greedy player vs the stub brain over HTTP
python tools/playtest.py --games=300 --decks=random --policy=random
python tools/playtest.py --brain=greedy         no server, Dealer is the in-process greedy bot (fastest)
python tools/playtest.py --brain=http://127.0.0.1:8775 --games=5   against an already running brain (e.g. the real one)
Other options pass through to playtest.gd (--player, --seed, --logs, --timeout, --report). Stub: --policy, --delay.
"""
import re
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
STUB_PORT = 8776   # not the real brain's 8775, so a running brain server is left alone
# exit-time noise from Godot's headless SceneTree, not game errors
NOISE = re.compile(r"ObjectDB instances were leaked|resources still in use at exit|^\s+at: (cleanup|clear) ")


def main():
    args = dict(a.lstrip("-").split("=", 1) if "=" in a else (a.lstrip("-"), "1") for a in sys.argv[1:])
    stub_opts = {k: args.pop(k) for k in ("policy", "delay") if k in args}
    args.setdefault("games", "100")
    stub = None
    if "brain" not in args:
        stub = subprocess.Popen([sys.executable, "-I", str(ROOT / "brain" / "stub_server.py"), f"--port={STUB_PORT}",
                                 *(f"--{k}={v}" for k, v in stub_opts.items())],
                                stdout=subprocess.PIPE, text=True)
        stub.stdout.readline()   # READY
        args["brain"] = f"http://127.0.0.1:{STUB_PORT}"
    t = time.time()
    try:
        p = subprocess.run(["godot_console", "--headless", "--path", str(ROOT), "--script", "res://scripts/playtest.gd",
                            "--", *(f"--{k}={v}" for k, v in args.items())],
                           capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=600)
    finally:
        if stub:
            stub.kill()
    out = p.stdout + p.stderr
    errors = [l for l in out.splitlines()
              if re.search(r"SCRIPT ERROR|^ERROR:|Parse Error", l) and not NOISE.search(l)]
    report = out[out.find("PLAYTEST"):] if "PLAYTEST" in out else ""
    print("\n".join(l for l in report.splitlines() if not re.search(r"^(WARNING|ERROR):|^\s+at: ", l)) or out)
    if stub_opts:
        print(f"  stub brain: {stub_opts}")
    print(f"  engine errors: {len(errors)}" + "".join(f"\n    {e}" for e in errors[:10]))
    print(f"  wall time {time.time() - t:.1f} s, godot exit {p.returncode}")
    sys.exit(1 if errors or p.returncode or not report else 0)


if __name__ == "__main__":
    main()
