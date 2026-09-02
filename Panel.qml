import QtQuick
import QtQuick.Controls
import Quickshell
import qs.Commons
import qs.Ui

// Bar widget plus popup for the Plain English activity report.
//
// All the thinking happens in bin/plain-english-activity, which prints one
// line of JSON per interval; ActivityState owns that process and this file
// only draws what it says. Keeping the narration in the helper means it can
// be read, tested, and argued with from a terminal
// (`plain-english-activity --text`) without going through Quickshell at all.
Panel {
  id: root
  moduleName: "joelgaff.plain-english"
  ipcTarget: "joelgaff.plain-english"

  readonly property bool showLabel: setting("showLabel", true) === true
  readonly property bool vertical: bar ? bar.vertical : false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property bool flagged: ActivityState.concerns.length > 0
  readonly property bool broken: ActivityState.error !== ""

  // The bar glyph earns its place by being different at a glance: a quiet
  // mark when nothing needs you, a filled alert when something does.
  readonly property string stateIcon: {
    if (broken) return "󰀦"
    if (flagged) return "󰀪"
    if (ActivityState.activity === "strained") return "󰀪"
    if (ActivityState.activity === "working") return "󰓅"
    if (ActivityState.activity === "busy") return "󰾅"
    return "󰾆"
  }

  readonly property color stateColor: {
    if (broken || flagged || ActivityState.activity === "strained") return urgent
    return barForeground
  }

  readonly property bool labelInBar: showLabel && !vertical && ActivityState.barLabel !== ""

  function toneColor(tone) {
    if (tone === "bad") return urgent
    if (tone === "warn") return Qt.lighter(urgent, 1.25)
    if (tone === "dim") return dim
    return foreground
  }

  // The helper marks the subject of each sentence with **bold**. Convert that
  // to the styled-text markup Text understands, escaping first so a window
  // title containing "<" cannot inject markup of its own.
  function richText(value) {
    var escaped = String(value)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
    return escaped.replace(/\*\*(.+?)\*\*/g, "<b>$1</b>")
  }

  function refresh() { ActivityState.restart() }
  function openBtop() {
    if (bar) bar.run("omarchy-launch-or-focus-tui btop")
  }

  // The singleton is shared, so the intervals follow whichever bar entry sets
  // them rather than each instance fighting over the value.
  function applyIntervals() {
    ActivityState.setInterval(setting("intervalSec", 5), setting("idleIntervalSec", 15))
  }

  onSettingsChanged: applyIntervals()
  Component.onCompleted: applyIntervals()

  // Tell the helper to sample often and collect window counts only while
  // someone is actually reading the report. Counted, not flagged, because a
  // widget exists per monitor. Component.onDestruction covers a plugin reload
  // that tears the widget down while its panel is open.
  onOpenedChanged: ActivityState.setPanelOpen(opened)
  Component.onDestruction: if (opened) ActivityState.setPanelOpen(false)

  // The bar reads the slot's width off the widget root, so a Panel that never
  // sizes itself is allotted zero pixels and renders as nothing at all.
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // WidgetButton rather than BarIconButton: the latter paints through an
  // icon-sized optical canvas, which is right for a lone glyph and wrong for a
  // glyph plus a word. A vertical bar has no room for the word either way.
  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.labelInBar ? root.stateIcon + "  " + ActivityState.barLabel : root.stateIcon
    labelVisible: true
    foreground: root.stateColor
    active: root.opened
    fixedWidth: root.labelInBar || root.vertical ? -1 : Style.bar.iconSlot
    tooltipText: root.labelInBar ? "" : (ActivityState.headline || "Plain English activity")

    onPressed: function(code) {
      if (code === Qt.RightButton) root.refresh()
      else if (code === Qt.MiddleButton) root.openBtop()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(460))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(860))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r" || t === "R") root.refresh()
        else if (t === "b" || t === "B") { root.openBtop(); root.close() }
      }

      Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: flick.width
          spacing: Style.space(12)

          PanelHero {
            width: parent.width
            title: ActivityState.headline !== "" ? ActivityState.headline : "Reading the system…"
            meta: ActivityState.uptime !== "" ? "Up " + ActivityState.uptime : ""
            foreground: root.flagged ? root.urgent : root.foreground
            fontFamily: root.fontFamily
            iconComponent: Component {
              Text {
                text: root.stateIcon
                textFormat: Text.PlainText
                color: root.flagged ? root.urgent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
          }

          Text {
            visible: ActivityState.summary !== ""
            width: parent.width
            text: ActivityState.summary
            textFormat: Text.PlainText
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Text {
            visible: root.broken
            width: parent.width
            text: ActivityState.error
            textFormat: Text.PlainText
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Text {
            visible: !ActivityState.everRead && !root.broken
            width: parent.width
            text: "Taking a first reading. CPU use has to be measured over time, "
                + "so this takes a moment."
            textFormat: Text.PlainText
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Repeater {
            model: ActivityState.sections

            // Named rather than reached through `parent`: inside a nested
            // Repeater, `parent` is the delegate's visual parent, not the
            // delegate holding modelData.
            Column {
              id: sectionBlock
              required property var modelData
              width: column.width
              spacing: Style.space(8)

              PanelSeparator { foreground: root.foreground }

              PanelSectionHeader {
                text: sectionBlock.modelData.title
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Repeater {
                model: sectionBlock.modelData.items

                Row {
                  id: lineRow
                  required property var modelData
                  width: sectionBlock.width
                  spacing: Style.space(8)

                  Text {
                    id: bullet
                    text: "•"
                    textFormat: Text.PlainText
                    color: root.toneColor(lineRow.modelData.tone)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                  }

                  Text {
                    width: lineRow.width - bullet.width - lineRow.spacing
                    text: root.richText(lineRow.modelData.text)
                    textFormat: Text.StyledText
                    color: root.toneColor(lineRow.modelData.tone)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    wrapMode: Text.WordWrap
                    lineHeight: 1.25
                  }
                }
              }
            }
          }

          PanelSeparator { foreground: root.foreground }

          Text {
            width: parent.width
            text: "r refresh · b open btop · Esc close"
            textFormat: Text.PlainText
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
          }
        }
      }
    }
  }
}
