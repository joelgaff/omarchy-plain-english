# Plain English

An Omarchy bar plugin that reads the same numbers `btop` shows you and says
what they mean.

`Super + Shift + T` opens btop, which tells you `bluetoothd 100.0 1686669 R`.
This tells you:

> **The Bluetooth service** (what manages your Bluetooth devices) is the
> busiest thing running — a whole CPU core and 8 MB of memory. This is a
> background service, not something you opened — it is supposed to sit idle.
> Using this much CPU means it is stuck, not busy.

A word in the bar (`Quiet`, `Busy`, `Working`, `Strained`, `Stuck`), and the
whole report when you click it.

## What it tells you

**What's running** — the handful of programs actually using the machine, named
in words rather than binaries, each with a line on whether that is normal.
A browser at two cores is ordinary; a background daemon at one core is stuck.
Processes are grouped by program, so Chrome's forty processes are one entry.

**Memory** — how much you are using, how much is left, whether that is
comfortable, and which program is holding the most.

**Energy** — battery percentage and real wattage where the hardware reports
it, how long that leaves you, what the CPU and GPU are burning, and how hot
things are running.

**Worth a look** — the section that answers "is anything actually wrong".
Reads the kernel's pressure-stall counters to catch the case where the CPU
looks idle but everything feels slow because programs are queued behind the
disk. Flags processes pegged for a long time, processes wedged on hardware,
and piles of zombies.

When nothing is wrong it says so plainly, which is the point: a monitor that
only ever shows numbers cannot tell you that you have nothing to worry about.

## Install

```bash
git clone https://github.com/<you>/omarchy-plain-english \
  ~/.config/omarchy/plugins/joel.plain-english
omarchy-shell shell rescanPlugins
omarchy plugin enable joel.plain-english
```

Move it in the bar with `omarchy bar move joel.plain-english --section right`.

## Use

| Action | What it does |
|---|---|
| Left click | Open or close the report |
| Right click | Take a fresh reading now |
| Middle click | Open btop, for when you want the raw numbers after all |
| `r` | Refresh, while the panel is open |
| `b` | Open btop and close the panel |
| `Esc` | Close |

It can also be summoned from a keybinding or a script:

```bash
omarchy-shell joel.plain-english toggle
```

To put that on a key, add to `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + ALT + T", "Activity in plain English",
  "omarchy-shell joel.plain-english toggle")
```

## Settings

In the plugin's entry under `bar.layout` in `~/.config/omarchy/shell.json`:

| Key | Default | Meaning |
|---|---|---|
| `intervalSec` | `5` | Seconds between readings |
| `showLabel` | `true` | Show the state word beside the icon |

## Reading it from a terminal

All the judgement lives in one dependency-free Python script, so you can read
the same report without the bar — and disagree with its wording where it is
wrong:

```bash
./bin/plain-english-activity --text     # human-readable, once
./bin/plain-english-activity            # one line of JSON, once
./bin/plain-english-activity --watch    # a line of JSON every interval
```

## How it works

`bin/plain-english-activity` reads `/proc` and `/sys` directly. No dependencies
beyond Python 3, no root, nothing installed.

- **CPU** is measured as a delta between two samples over a real interval and
  reported in cores, not percentages, because "40%" begs "of what".
- **Memory** comes from `MemAvailable`, not `free` — the number that accounts
  for reclaimable cache.
- **Power** comes from the battery's own counters, handling both the
  energy-reporting (`power_now`) and charge-reporting (`current_now` ×
  `voltage_now`) kinds. On AMD APUs, the `amdgpu` hwmon's PPT covers the CPU
  and GPU package together, which is the best whole-chip wattage available
  without root. Intel's RAPL counters are root-only, so they are skipped.
- **Stalls** come from `/proc/pressure/*` — the share of time work was blocked
  waiting on CPU, memory, or I/O. This is what explains a machine that feels
  slow while every usage bar looks fine.
- **Runaways** are caught two ways: three consecutive busy samples, or a
  lifetime CPU average that is already high, which catches something that has
  been spinning since before the plugin started watching.
- **Windows** come from `hyprctl clients`, so a program can be described by how
  many windows you have open, not just how many processes it spawned.

The narration is a deterministic rule engine over that data — no model, no
network, no telemetry. The same numbers always produce the same sentences.
Unrecognised programs are shown by their real name and labelled as
unrecognised rather than given an invented description, and per-process
wattage is never claimed, because the hardware does not measure it.

`ActivityState.qml` is a singleton so one helper serves every monitor's bar
rather than one per screen. `Panel.qml` only draws what it is told.

## Adding a program it does not recognise

Process descriptions live in the `PROCESSES` table at the top of
`bin/plain-english-activity`:

```python
"nvim": ("Neovim", "your editor", "app"),
```

The third field decides the tone of the "should I worry" sentence: `app`,
`browser`, `dev`, `agent`, `system`, `kernel`, or `media`. A `system` process
burning a core is called stuck; a `dev` process burning a core is called a
build.

## Licence

MIT.
