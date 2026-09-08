#!/usr/bin/env python3
"""Tests for the supervisor that sits between the worker and the front-end.

Quickshell's parsers cannot cap bytes before a newline arrives and its Process
cannot signal a process group, so both bounds live here. These tests pin them:
frames are forwarded intact, an unterminated or oversized line is fatal to the
worker rather than to memory, stderr overflow is dropped rather than fatal,
control lines are relayed, and no worker outlives its supervisor.
"""

import io
import json
import os
import signal
import subprocess
import sys
import threading
import time
import types

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(ROOT, "bin", "plain-english-activity")
src = open(SCRIPT, encoding="utf-8").read()
src = src.replace('if __name__ == "__main__":', "if False:")
pea = types.ModuleType("pea")
exec(compile(src, "plain-english-activity", "exec"), pea.__dict__)

failures = 0


def check(label, got, want):
    global failures
    ok = got == want
    print("  %s %-36s got %r" % ("PASS " if ok else "FAIL ", label, got))
    if not ok:
        print("         expected %r" % (want,))
        failures += 1


def alive(pid):
    try:
        with open("/proc/%d/stat" % pid) as handle:
            return "Z" not in handle.read().rsplit(")", 1)[1].split()[0]
    except OSError:
        return False


def children_of(pid):
    out = []
    for entry in os.listdir("/proc"):
        if not entry.isdigit():
            continue
        try:
            with open("/proc/%s/stat" % entry) as handle:
                fields = handle.read().rsplit(")", 1)[1].split()
        except OSError:
            continue
        if fields[1] == str(pid):
            out.append(int(entry))
    return out


def run(script, close_stdin_after=None, send=None):
    """Supervise a fake worker in-process. Returns (code, frames, stderr, pid).

    The fake worker always prints its pid as the first line so the test can
    prove it was reaped.
    """
    body = "import os,sys,time;sys.stdout.write(str(os.getpid())+'\\n');sys.stdout.flush()\n" + script
    r, w = os.pipe()
    out = io.BytesIO()
    err = io.StringIO()
    control = os.fdopen(r, "rb", buffering=0)

    finished = threading.Event()

    def driver():
        # Never touch `w` after supervise() has returned: the descriptor
        # number may already belong to a later test's pipe.
        if send is not None and not finished.wait(0.3):
            os.write(w, send)
        if close_stdin_after is not None and not finished.wait(close_stdin_after):
            os.close(w)
            closed.append(True)
    closed = []
    thread = threading.Thread(target=driver, daemon=True)
    thread.start()

    start = time.monotonic()
    code = pea.supervise([sys.executable, "-c", body], stdin=control, out=out, err=err)
    elapsed = time.monotonic() - start
    finished.set()
    thread.join(timeout=2)
    control.close()
    if not closed:
        os.close(w)
    frames = out.getvalue().split(b"\n")
    frames = [f for f in frames if f != b""]
    pid = int(frames[0]) if frames else None
    return code, frames[1:], err.getvalue(), pid, elapsed


# 1. The framer on its own.
f = pea.LineFramer(8, "fatal")
check("framer splits complete lines", f.feed(b"ab\ncd\n"), [b"ab", b"cd"])
check("framer holds a partial line", f.feed(b"ef"), [])
check("framer completes it later", f.feed(b"g\n"), [b"efg"])
check("framer not overflowed", f.overflowed, False)
check("framer rejects long complete line", f.feed(b"123456789\nok\n"), [])
check("framer fatal after overflow", f.overflowed, True)
check("framer accepts nothing after fatal", f.feed(b"ok\n"), [])
f = pea.LineFramer(8, "fatal")
f.feed(b"12345")
check("framer unterminated overflow", (f.feed(b"6789"), f.overflowed), ([], True))
d = pea.LineFramer(8, "drop")
check("drop framer skips long line", d.feed(b"123456789012\nok\n"), [b"ok"])
check("drop framer counts it", d.dropped, 1)
d = pea.LineFramer(8, "drop")
d.feed(b"1234567890")
check("drop framer discards to newline", d.feed(b"junk\nfine\n"), [b"fine"])
check("drop framer bounded pending", len(d.pending) <= 8, True)

# 2. Normal worker: frames arrive intact, stdin EOF stops everything.
code, frames, err, pid, elapsed = run(
    "sys.stdout.write('hello\\nworld\\n');sys.stdout.flush();time.sleep(300)",
    close_stdin_after=0.5)
check("frames forwarded intact", frames, [b"hello", b"world"])
check("stdin EOF exits zero", code, 0)
check("stdin EOF stops promptly", elapsed < 3.0, True)
check("worker reaped on EOF", alive(pid), False)

# 3. Unterminated flood: must be fatal within the byte cap, not the clock.
code, frames, err, pid, elapsed = run(
    "while True: sys.stdout.write('x'*4096); sys.stdout.flush()")
check("unterminated flood is fatal", code, 1)
check("flood forwarded nothing", frames, [])
check("flood stopped promptly", elapsed < 3.0, True)
check("flooding worker reaped", alive(pid), False)
check("flood reason on stderr", "over %d bytes" % pea.MAX_FRAME_BYTES in err, True)

# 4. Oversized but terminated line: same outcome, nothing forwarded.
code, frames, err, pid, elapsed = run(
    "sys.stdout.write('y'*%d+'\\n');sys.stdout.flush();time.sleep(300)"
    % (pea.MAX_FRAME_BYTES + 1))
check("oversized line is fatal", code, 1)
check("oversized line not forwarded", frames, [])
check("oversized worker reaped", alive(pid), False)

# 5. A line exactly at the cap passes.
code, frames, err, pid, elapsed = run(
    "sys.stdout.write('z'*%d+'\\n');sys.stdout.flush()" % pea.MAX_FRAME_BYTES,
    close_stdin_after=2.0)
check("line at cap forwarded", frames == [b"z" * pea.MAX_FRAME_BYTES], True)

# 6. stderr flood without a newline is bounded and dropped, never fatal.
code, frames, err, pid, elapsed = run(
    "sys.stderr.write('e'*4096);sys.stderr.flush();sys.stderr.write('short\\n');"
    "sys.stderr.flush();sys.stdout.write('ok\\n');sys.stdout.flush();time.sleep(300)",
    close_stdin_after=1.0)
check("stdout survives stderr flood", frames, [b"ok"])
check("stderr flood exit zero", code, 0)
check("oversized stderr line dropped", "eeee" in err, False)
check("stderr drop reported", "dropped 1 oversized stderr" in err, True)

# 7. Short stderr lines are relayed.
code, frames, err, pid, elapsed = run(
    "sys.stderr.write('warn: x\\n');sys.stderr.flush();time.sleep(300)",
    close_stdin_after=0.5)
check("stderr line relayed", "warn: x" in err, True)

# 8. Control lines reach the worker.
code, frames, err, pid, elapsed = run(
    "line=sys.stdin.readline();sys.stdout.write('got '+line.strip()+'\\n');"
    "sys.stdout.flush();time.sleep(300)",
    send=b"open\n", close_stdin_after=1.0)
check("control line relayed", frames, [b"got open"])

# 9. A worker that exits by itself passes its code through.
code, frames, err, pid, elapsed = run("sys.stdout.write('bye\\n');sys.exit(3)")
check("worker exit code passed through", code, 3)
check("final frames flushed", frames, [b"bye"])

# 10. The real thing: SIGTERM to the supervisor reaps the real worker.
proc = subprocess.Popen(
    [SCRIPT, "--watch", "--interval", "2", "--idle-interval", "2"],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
first = proc.stdout.readline()
try:
    report = json.loads(first)
except ValueError:
    report = None
check("real first frame is a report", isinstance(report, dict) and "state" in report, True)
workers = children_of(proc.pid)
check("real worker is a child", len(workers), 1)
proc.send_signal(signal.SIGTERM)
try:
    code = proc.wait(timeout=5)
except subprocess.TimeoutExpired:
    proc.kill()
    code = None
time.sleep(0.2)
check("real supervisor exits on TERM", code, 0)
check("real worker reaped on TERM", any(alive(w) for w in workers), False)
proc.stdout.close(); proc.stderr.close(); proc.stdin.close()

# 11. The worker dies with its supervisor even on SIGKILL (PDEATHSIG).
proc = subprocess.Popen(
    [SCRIPT, "--watch", "--interval", "2", "--idle-interval", "2"],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
proc.stdout.readline()
workers = children_of(proc.pid)
proc.kill()
proc.wait(timeout=5)
deadline = time.monotonic() + 3.0
while time.monotonic() < deadline and any(alive(w) for w in workers):
    time.sleep(0.05)
check("worker follows SIGKILLed supervisor", any(alive(w) for w in workers), False)
proc.stdout.close(); proc.stdin.close()

# 12. Nothing left registered.
check("no children left registered", len(pea.LIVE_CHILDREN), 0)

print()
if failures:
    print("%d supervisor test(s) failed" % failures)
    sys.exit(1)
print("all supervisor tests passed")
