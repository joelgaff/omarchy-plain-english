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
QtObject {
  id: root

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

  function setPanelOpen(open) {
    root.openPanels = Math.max(0, root.openPanels + (open ? 1 : -1))
  }

  // Tell the helper which cadence to use. It also skips the hyprctl window
  // lookup while closed, since window counts only appear in the popup.
  onAnyPanelOpenChanged: {
    if (reporter.running) reporter.write(root.anyPanelOpen ? "open\n" : "closed\n")
  }

  property string activity: "quiet"
  property string barLabel: ""
  property string headline: ""
  property string summary: ""
  property var lines: []
  property var concerns: []
  property real cpuPercent: 0
  property real memPercent: 0
  property string uptime: ""
  property var power: ({})
  property var thermals: ({})
  property int cores: 0
  property string error: ""
  property bool everRead: false

  // Sections come back interleaved with their lines; group them once here so
  // every popup does not regroup the same list.
  readonly property var sections: {
    var out = []
    var current = null
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i]
      if (!current || current.title !== line.section) {
        current = { "title": line.section, "items": [] }
        out.push(current)
      }
      current.items.push(line)
    }
    return out
  }

  function apply(json) {
    var report
    try {
      report = JSON.parse(json)
    } catch (e) {
      return
    }
    if (!report || typeof report !== "object") return

    root.activity = report.state || "quiet"
    root.barLabel = report.barLabel || ""
    root.headline = report.headline || ""
    root.summary = report.summary || ""
    root.lines = report.lines || []
    root.concerns = report.concerns || []
    root.cpuPercent = report.cpuPercent || 0
    root.memPercent = report.memPercent || 0
    root.uptime = report.uptime || ""
    root.power = report.power || ({})
    root.thermals = report.thermals || ({})
    root.cores = report.cores || 0
    root.error = ""
    root.everRead = true
  }

  function restart() {
    reporter.running = false
    reporter.running = true
  }

  function setInterval(seconds, idleSeconds) {
    var value = Math.max(2, Math.round(seconds))
    var idle = Math.max(value, Math.round(idleSeconds || root.idleIntervalSec))
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
    onStarted: if (root.anyPanelOpen) write("open\n")

    stdout: SplitParser {
      onRead: function(line) {
        if (line && line.length > 0) root.apply(line)
      }
    }

    stderr: StdioCollector {
      onStreamFinished: {
        var text = String(this.text || "").trim()
        if (text !== "" && !root.everRead) root.error = text.split("\n").pop()
      }
    }

    onExited: function(exitCode) {
      if (exitCode !== 0 && !root.everRead && root.error === "")
        root.error = "The activity helper stopped (exit " + exitCode + ")."
    }
  }
}
