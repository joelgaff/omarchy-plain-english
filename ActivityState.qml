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

  // Seconds between readings. Widgets write this from their settings; the
  // helper is restarted when it changes.
  property int intervalSec: 5

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

  function setInterval(seconds) {
    var value = Math.max(2, Math.round(seconds))
    if (value === root.intervalSec) return
    root.intervalSec = value
    if (reporter.running) restart()
  }

  // One long-lived helper rather than a process per refresh: CPU figures are
  // deltas between consecutive samples, so a process starting fresh each time
  // would have to sleep before it could measure anything, and would lose the
  // history that separates "busy right now" from "stuck for an hour".
  property Process reporter: Process {
    running: true
    command: [
      root.pluginDir + "/bin/plain-english-activity",
      "--watch",
      "--interval",
      String(root.intervalSec)
    ]

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
