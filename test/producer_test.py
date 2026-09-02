#!/usr/bin/env python3
"""Bounds tests for the helper's emitted reports.

The front-end parses our stdout on every tick for the life of the session, so
an unbounded or malformed report is its problem. These tests pin the caps.
"""

import json
import os
import sys
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
    print("  %s %-32s got %r" % ("PASS " if ok else "FAIL ", label, got))
    if not ok:
        print("         expected %r" % (want,))
        failures += 1


def check_true(label, got):
    check(label, bool(got), True)


# ---- clamp ----------------------------------------------------------------

check("clamp strips NUL", pea.clamp("a\x00b", 50), "ab")
check("clamp strips ESC", pea.clamp("a\x1b[31mb", 50), "a[31mb")
check("clamp strips newline", pea.clamp("a\nb", 50), "ab")
check("clamp strips U+2028", pea.clamp("a b", 50), "ab")
check("clamp truncates", len(pea.clamp("x" * 500, 32)), 32)
check("clamp keeps short text", pea.clamp("hello", 32), "hello")

# ---- unknown process names are clamped ------------------------------------

long_name = "z" * 300
display, description, kind = pea.friendly(long_name)
check("unknown name clamped", len(display) <= pea.MAX_NAME_CHARS, True)
check("unknown name kind", kind, "unknown")

# ---- report encoding ------------------------------------------------------

base = {
    "state": "busy",
    "barLabel": "Busy",
    "headline": "h",
    "summary": "s",
    "lines": [{"section": "S", "text": "t", "tone": "normal", "title": ""}],
    "concerns": [],
    "ts": 0,
}

blob = pea.encode_report(base)
check("small report parses", json.loads(blob)["state"], "busy")
check("no embedded newline", "\n" in blob, False)

huge = dict(base)
huge["lines"] = [
    {"section": "S" * 100, "text": "Y" * 5000, "tone": "normal", "title": ""}
    for _ in range(400)
]
blob = pea.encode_report(huge)
check("oversized within cap", len(blob) <= pea.MAX_REPORT_BYTES, True)
check_true("oversized still parses", json.loads(blob))
check("oversized flagged", json.loads(blob).get("truncated"), True)
check("oversized has no newline", "\n" in blob, False)

# A single line too large for the cap must still yield a valid minimal report.
absurd = dict(base)
absurd["summary"] = "q" * (pea.MAX_REPORT_BYTES * 3)
blob = pea.encode_report(absurd)
check("absurd within cap", len(blob) <= pea.MAX_REPORT_BYTES, True)
check_true("absurd still parses", json.loads(blob))

# ---- narration bounds -----------------------------------------------------

sample = {
    "cpuPercent": 5.0,
    "memory": {"total": 8 << 30, "available": 4 << 30, "used": 4 << 30,
               "cached": 0, "swapTotal": 0, "swapUsed": 0},
    "pressure": {},
    "power": {"present": False},
    "thermals": {},
    "gpuBusy": None,
    "uptime": 100.0,
    "zombies": 0,
    "stuck": [],
}
groups = [
    {"name": "x%d" % i, "cores": 2.0, "mem": 1 << 20, "pids": 1, "windows": 0,
     "lifetime": 0.0, "age": 10.0, "friendly": ("x%d" % i, "", "unknown"),
     "sustained": False, "sustainedFor": 0}
    for i in range(200)
]
report = pea.Narrator(dict(sample)).run(groups, sample)
check("lines capped", len(report["lines"]) <= pea.MAX_LINES, True)
check("concerns capped", len(report["concerns"]) <= pea.MAX_CONCERNS, True)
check("every tone valid", all(l["tone"] in pea.TONES for l in report["lines"]), True)
check("every line clamped",
      all(len(l["text"]) <= pea.MAX_TEXT_CHARS for l in report["lines"]), True)

print()
if failures:
    print("%d producer test(s) failed" % failures)
    sys.exit(1)
print("all producer tests passed")
