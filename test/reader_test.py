#!/usr/bin/env python3
"""Tests for the bounded, deadline-driven child reader.

A plain read(n) blocks until it has n bytes or sees EOF, so a child that
prints a little and then hangs makes a later wait(timeout=...) unreachable.
These tests pin the behaviour that replaced it.
"""

import os
import subprocess
import sys
import time
import types

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
src = open(os.path.join(ROOT, "bin", "plain-english-activity"), encoding="utf-8").read()
src = src.replace('if __name__ == "__main__":', "if False:")
pea = types.ModuleType("pea")
exec(compile(src, "plain-english-activity", "exec"), pea.__dict__)

failures = 0


def check(label, got, want):
    global failures
    ok = got == want
    print("  %s %-34s got %r" % ("PASS " if ok else "FAIL ", label, got))
    if not ok:
        print("         expected %r" % (want,))
        failures += 1


def spawn(script):
    return subprocess.Popen(
        [sys.executable, "-c", script],
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, start_new_session=True,
    )


# 1. Normal child: output is returned intact.
p = spawn("import sys; sys.stdout.write('hello'); sys.stdout.flush()")
got = pea.read_bounded(p.stdout, 1024, 3.0)
pea.terminate_group(p)
check("normal output returned", got, b"hello")

# 2. The reported bug: prints a little, then never exits. Must return by the
#    deadline rather than blocking forever.
p = spawn("import sys,time; sys.stdout.write('x'); sys.stdout.flush(); time.sleep(300)")
start = time.monotonic()
got = pea.read_bounded(p.stdout, 1024, 1.0)
elapsed = time.monotonic() - start
pea.terminate_group(p)
check("hanging child returns None", got, None)
check("returned within deadline", elapsed < 2.5, True)
check("hanging child was reaped", p.poll() is not None, True)

# 3. Child that floods: must stop at the cap, not buffer without limit.
p = spawn("import sys\nwhile True: sys.stdout.write('y'*4096); sys.stdout.flush()")
start = time.monotonic()
got = pea.read_bounded(p.stdout, 65536, 5.0)
elapsed = time.monotonic() - start
pea.terminate_group(p)
check("flooding child returns None", got, None)
check("flood stopped promptly", elapsed < 5.0, True)
check("flooding child was reaped", p.poll() is not None, True)

# 4. Child that exits without output: EOF is not an error.
p = spawn("pass")
got = pea.read_bounded(p.stdout, 1024, 3.0)
pea.terminate_group(p)
check("clean EOF returns bytes", got, b"")

# 5. Bounded /proc reads.
check("read caps oversized file", pea.read("/proc/self/cmdline", "D", 0), "D")
check("read returns small file", len(pea.read("/proc/self/stat")) > 0, True)
check("read missing file default", pea.read("/proc/does-not-exist", "D"), "D")

# 6. No child outlives the reader.
check("no children left registered", len(pea.LIVE_CHILDREN), 0)

print()
if failures:
    print("%d reader test(s) failed" % failures)
    sys.exit(1)
print("all reader tests passed")
