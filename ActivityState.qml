pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// The single owner of the reporter process and everything it reports.
//
// A bar widget is instantiated once per monitor, so starting the helper from
// the widget would walk /proc once per screen every few seconds and produce
// two sets of numbers that disagree. Everything stateful lives here instead:
// one helper however many bars are on the desk, and every popup showing the
// same reading at the same moment.
//
// Nothing arriving from the helper is trusted. It reports on processes, and a
// process names itself, so its output is attacker-influenced by construction.
// The helper bounds what it emits; this file bounds what it accepts, and the
// redundancy is deliberate -- an older or replaced helper cannot lift a cap.
QtObject {
  id: root

  // Ingest limits, mirroring the caps in bin/plain-english-activity.
  readonly property int maxLineBytes: 65536
  readonly property int maxLines: 24
  readonly property int maxTextChars: 400
  readonly property int maxConcerns: 8
  readonly property int maxSections: 8
  readonly property int maxStderrChars: 2000

  readonly property var validTones: ["normal", "good", "warn", "bad", "dim"]
  readonly property var validStates: ["quiet", "busy", "working", "strained"]

  // Derived from this file's own location rather than a hardcoded install
  // path: the plugin still works when it is cloned under a different
  // directory name, symlinked from a checkout, or renamed.
  readonly property string pluginDir: {
    var dir = Qt.resolvedUrl(".").toString()
    if (dir.indexOf("file://") === 0) dir = dir.substring(7)
    return dir.replace(/\/$/, "")
  }

  // Two cadences. `intervalSec` applies while a panel is open and someone is
  // reading; `idleIntervalSec` applies while every panel is closed and only
  // the bar word is on screen. Widgets write both from their settings.
  property int intervalSec: 5
  property int idleIntervalSec: 15

  // A bar widget exists per monitor, so panels are counted rather than
  // flagged: the helper stays in fast mode until the last one closes.
  property int openPanels: 0
  readonly property bool anyPanelOpen: openPanels > 0

  property string activity: "quiet"
  property string barLabel: ""
  property string headline: ""
  property string summary: ""
  property var lines: []
  property var concerns: []
  property real cpuPercent: 0
  property real memPercent: 0
  property string uptime: ""
  property int cores: 0
  property bool truncated: false
  property string error: ""
  property bool everRead: false

  // Supervision state.
  property int restarts: 0
  property bool stopping: false
  property string stderrTail: ""

  // Quickshell's DataStreamParser types expose no buffer cap: SplitParser has
  // only splitMarker, StdioCollector only text/data/waitForEnd, and FileView
  // has no size limit either. So a byte cap cannot be enforced inside the
  // parser, before delimiter buffering. Nor can Process signal a process
  // group. Both bounds therefore live one layer down: the process launched
  // here is the helper's supervisor, which frames the sampling worker's
  // stdout and stderr under hard byte caps, forwards only complete lines,
  // and owns the worker's session -- killing the whole group on overflow,
  // on SIGTERM, or when this side goes away. What reaches SplitParser is
  // always newline-terminated and under 16KB, or the supervisor has already
  // exited non-zero and the backoff restart below applies.
  //
  // That bounds memory in bytes. The stall watchdog is the bound in time:
  // a helper that is alive but silent -- wedged, or a supervisor that is
  // itself stuck -- is detected by the absence of reports and replaced.
  function killHelper(reason) {
    root.error = reason
    if (!reporter.running) return
    // SIGTERM rather than SIGKILL: the supervisor traps it and tears down
    // the worker's group. forceKill closes the window if it does not go
    // quietly. The timer is cancelled in onExited, so it can only ever act
    // on the process it was armed for, never on a replacement.
    reporter.signal(15)
    forceKill.restart()
  }

  // Three of the longest interval the helper may legitimately be quiet for.
  // The idle interval counts too: while the panel is closed the helper
  // reports at that cadence, and a watchdog set from the open interval alone
  // would kill a healthy helper whenever idleIntervalSec exceeded ten seconds.
  function noteProgress() {
    var longest = Math.max(root.intervalSec, root.idleIntervalSec)
    stallWatchdog.interval = Math.max(30000, longest * 3000)
    stallWatchdog.restart()
  }

  function setPanelOpen(open) {
    root.openPanels = Math.max(0, root.openPanels + (open ? 1 : -1))
  }

  // Tell the helper which cadence to use. It also skips the hyprctl window
  // lookup while closed, since window counts only appear in the popup.
  onAnyPanelOpenChanged: {
    if (reporter.running) reporter.write(root.anyPanelOpen ? "open\n" : "closed\n")
  }

  // ---- validation ---------------------------------------------------------
  //
  // Every field is coerced to its expected type with an explicit bound. A
  // missing, mistyped, or oversized value becomes a safe default rather than
  // reaching a property binding.

  function safeString(value, limit) {
    if (typeof value !== "string") return ""
    // Strip C0/C1 controls and Unicode line separators: they cannot render
    // usefully, and would let a program name break the panel's layout.
    // Also strip angle brackets. Several sinks are shared Ui components
    // (PanelHero, PanelSectionHeader) whose Text defaults to AutoText, which
    // renders anything that looks like markup. We cannot set PlainText on
    // those from here, so no raw "<" is allowed through in the first place.
    // Our own narration never uses angle brackets, so nothing legitimate is
    // lost. richText() still escapes on the way out, deliberately twice.
    var cleaned = value.replace(/[\x00-\x1F\x7F-\x9F\u2028\u2029<>]/g, "")
    return cleaned.length > limit ? cleaned.substring(0, limit) : cleaned
  }

  function safeNumber(value, low, high) {
    var n = Number(value)
    if (!isFinite(n)) return low
    return Math.min(high, Math.max(low, n))
  }

  function safeEnum(value, allowed, fallback) {
    return allowed.indexOf(value) >= 0 ? value : fallback
  }

  function safeStringList(value, maxItems, limit) {
    if (!Array.isArray(value)) return []
    var out = []
    for (var i = 0; i < value.length && out.length < maxItems; i++) {
      var s = safeString(value[i], limit)
      if (s !== "") out.push(s)
    }
    return out
  }

  function safeLines(value) {
    if (!Array.isArray(value)) return []
    var out = []
    for (var i = 0; i < value.length && out.length < root.maxLines; i++) {
      var item = value[i]
      if (!item || typeof item !== "object" || Array.isArray(item)) continue
      var text = safeString(item.text, root.maxTextChars)
      if (text === "") continue
      out.push({
        "section": safeString(item.section, 40),
        "text": text,
        "tone": safeEnum(item.tone, root.validTones, "normal")
      })
    }
    return out
  }

  // Sections come back interleaved with their lines; group them once here so
  // every popup does not regroup the same list. Bounded so a report with many
  // distinct section names cannot create unbounded delegates.
  readonly property var sections: {
    var out = []
    var current = null
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i]
      if (!current || current.title !== line.section) {
        if (out.length >= root.maxSections) break
        current = { "title": line.section, "items": [] }
        out.push(current)
      }
      current.items.push(line)
    }
    return out
  }

  function apply(json) {
    // Bound before parsing: a huge line must never become a huge JS object
    // graph, and JSON.parse on megabytes would block the shell's UI thread --
    // which draws the bar, notifications, and OSD for the whole session.
    if (typeof json !== "string" || json.length === 0) return
    if (json.length > root.maxLineBytes) {
      // Terminating rather than skipping: a helper emitting oversized lines
      // will keep doing it, and each one costs a full parse.
      killHelper("The activity helper sent an oversized report and was stopped.")
      return
    }

    var report
    try {
      report = JSON.parse(json)
    } catch (e) {
      return
    }
    // Arrays are objects in JS, so a top-level array would pass a naive check.
    if (!report || typeof report !== "object" || Array.isArray(report)) return

    root.activity = safeEnum(report.state, root.validStates, "quiet")
    root.barLabel = safeString(report.barLabel, 24)
    root.headline = safeString(report.headline, root.maxTextChars)
    root.summary = safeString(report.summary, root.maxTextChars)
    root.lines = safeLines(report.lines)
    root.concerns = safeStringList(report.concerns, root.maxConcerns, root.maxTextChars)
    root.cpuPercent = safeNumber(report.cpuPercent, 0, 100)
    root.memPercent = safeNumber(report.memPercent, 0, 100)
    root.uptime = safeString(report.uptime, 32)
    root.cores = Math.round(safeNumber(report.cores, 0, 4096))
    root.truncated = report.truncated === true
    root.error = ""
    root.everRead = true
    root.restarts = 0
    noteProgress()
  }

  function restart() {
    root.stopping = true
    reporter.running = false
    reporter.running = true
    root.stopping = false
  }

  function setInterval(seconds, idleSeconds) {
    var value = Math.round(safeNumber(seconds, 2, 300))
    var idle = Math.max(value, Math.round(safeNumber(idleSeconds, 2, 3600)))
    if (value === root.intervalSec && idle === root.idleIntervalSec) return
    root.intervalSec = value
    root.idleIntervalSec = idle
    if (reporter.running) restart()
  }

  // One long-lived helper rather than a process per refresh: CPU figures are
  // deltas between consecutive samples, so a process starting fresh each time
  // would have to sleep before it could measure anything, and would lose the
  // history that separates "busy right now" from "stuck for an hour".
  property Process reporter: Process {
    running: true
    stdinEnabled: true
    command: [
      root.pluginDir + "/bin/plain-english-activity",
      "--watch",
      "--interval",
      String(root.intervalSec),
      "--idle-interval",
      String(root.idleIntervalSec)
    ]

    // A restart loses the helper's idea of panel state, so re-assert it.
    onStarted: {
      // A pending escalation belongs to a previous process, never this one.
      forceKill.stop()
      if (root.anyPanelOpen) write("open\n")
      root.noteProgress()
    }

    stdout: SplitParser {
      onRead: function(line) { root.apply(line) }
    }

    // SplitParser rather than StdioCollector: a collector accumulates the
    // whole stream for the life of the process, which for a daemon running
    // for days is unbounded. Only a short tail is ever useful.
    stderr: SplitParser {
      onRead: function(line) {
        var text = root.safeString(line, 200)
        if (text === "") return
        var tail = root.stderrTail + text + "\n"
        if (tail.length > root.maxStderrChars)
          tail = tail.substring(tail.length - root.maxStderrChars)
        root.stderrTail = tail
      }
    }

    onExited: function(exitCode) {
      // The process forceKill was armed for is gone, whether it went quietly
      // or not. Left running, the timer would fire after the supervised
      // restart and stop the healthy replacement instead.
      forceKill.stop()
      stallWatchdog.stop()
      if (root.stopping) return
      // Supervision: a helper that dies leaves the bar frozen on a stale
      // reading with nothing to say it has stopped. Restart it, backing off
      // so a helper that crashes at startup cannot become a spawn loop.
      root.restarts += 1
      if (root.restarts <= 5) {
        supervisor.interval = Math.min(60000, 1000 * Math.pow(2, root.restarts - 1))
        supervisor.restart()
        return
      }
      root.error = "The activity helper keeps stopping (exit " + exitCode
        + "). Run bin/plain-english-activity --text in a terminal to see why."
    }
  }

  property Timer supervisor: Timer {
    repeat: false
    onTriggered: if (!reporter.running) reporter.running = true
  }

  // No valid report within three intervals means the helper is wedged, silent,
  // or buffering something it will never terminate. Any of those warrant the
  // same response.
  property Timer stallWatchdog: Timer {
    repeat: false
    onTriggered: root.killHelper("The activity helper stopped reporting and was restarted.")
  }

  // Escalation if SIGTERM is ignored. Dropping running to false makes
  // Quickshell tear the process down, which fires onExited and the usual
  // supervised restart. The worker asks the kernel for SIGTERM when its
  // supervisor dies, so even this path does not orphan it.
  property Timer forceKill: Timer {
    interval: 3000
    repeat: false
    onTriggered: if (reporter.running) reporter.running = false
  }
}
