import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "io.github.saiemsaeed.luma"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root
  readonly property string controllerPath: decodeURIComponent(
    Qt.resolvedUrl("control.py").toString().replace(/^file:\/\//, "")
  )
  readonly property string lightHost: String(setting("host", "elgato-key-light-mk-2-2840.local"))
  readonly property int lightPort: parseInt(setting("port", 9123), 10) || 9123
  readonly property int refreshInterval: Math.max(2, parseInt(setting("refreshIntervalSec", 5), 10) || 5)
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  property bool available: false
  property bool lightOn: false
  property int brightness: 0
  property int kelvin: 0
  property string deviceName: "Key Light"
  property string feedback: ""
  readonly property bool busy: actionProc.running

  function open() {
    root.controller.show()
    refresh()
  }

  function close() { root.controller.hide() }
  function toggle() { if (root.opened) close(); else open() }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function refresh() {
    if (!snapshotProc.running && !actionProc.running) snapshotProc.running = true
  }

  function command(action, extra) {
    return ["python3", root.controllerPath, action,
      "--host", root.lightHost, "--port", String(root.lightPort)].concat(extra || [])
  }

  function runAction(action, extra) {
    if (actionProc.running) return
    feedback = ""
    actionProc.command = command(action, extra)
    actionProc.running = true
  }

  function togglePower() { runAction("toggle") }
  function setBrightness(value) {
    runAction("set", ["--brightness", String(Math.max(3, Math.min(100, value)))])
  }
  function setKelvin(value) {
    runAction("set", ["--kelvin", String(Math.max(2900, Math.min(7000, value)))])
  }
  function setScene(name) { runAction("scene", ["--name", name]) }
  function identify() { runAction("identify") }
  function launchLuma() { runAction("launch") }

  function applyResponse(raw) {
    var text = String(raw || "").trim()
    if (!text) return
    try {
      var response = JSON.parse(text)
      if (response.available !== undefined) available = response.available === true
      if (response.on !== undefined) lightOn = response.on === true
      if (response.brightness !== undefined) brightness = Number(response.brightness)
      if (response.kelvin !== undefined) kelvin = Number(response.kelvin)
      if (response.name) deviceName = String(response.name)
      if (response.message) feedback = String(response.message)
      else if (response.error) feedback = String(response.error)
    } catch (error) {
      feedback = "Luma returned an invalid response"
    }
  }

  Process {
    id: snapshotProc
    command: root.command("snapshot", [])
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyResponse(text)
    }
  }

  Process {
    id: actionProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyResponse(text)
    }
    onExited: Qt.callLater(root.refresh)
  }

  Timer {
    interval: root.refreshInterval * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onActivateRequested: root.togglePower()
      onTextKey: function(text) {
        if (text === "r" || text === "R") root.refresh()
        else if (text === "o" || text === "O") root.launchLuma()
      }

      Column {
        id: content
        width: parent.width
        spacing: Style.space(14)

        Row {
          width: parent.width
          spacing: Style.space(12)

          Text {
            text: "󰛨"
            color: root.lightOn ? Color.accent : root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.display
            anchors.verticalCenter: parent.verticalCenter
          }

          Column {
            width: parent.width - parent.spacing - Style.space(44)
            spacing: Style.space(2)

            Text {
              width: parent.width
              text: root.deviceName
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
            }

            Text {
              text: !root.available ? "UNAVAILABLE" : (root.lightOn ? "ON" : "OFF")
              color: root.available ? (root.lightOn ? Color.accent : Qt.darker(root.foreground, 1.4)) : root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
            }
          }
        }

        Button {
          width: parent.width
          text: root.lightOn ? "Turn Off" : "Turn On"
          iconText: "󰛨"
          bordered: true
          foreground: root.lightOn ? Color.accent : root.foreground
          fontFamily: root.fontFamily
          enabled: root.available && !root.busy
          onClicked: root.togglePower()
        }

        PanelSeparator { foreground: root.foreground }

        PanelSectionHeader {
          text: "BRIGHTNESS"
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        Row {
          width: parent.width
          spacing: Style.space(8)

          Button {
            width: (parent.width - parent.spacing * 2) / 3
            text: "− 5"
            bordered: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            enabled: root.available && !root.busy
            onClicked: root.setBrightness(root.brightness - 5)
          }
          Button {
            width: (parent.width - parent.spacing * 2) / 3
            text: root.available ? root.brightness + "%" : "—"
            bordered: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            enabled: false
          }
          Button {
            width: (parent.width - parent.spacing * 2) / 3
            text: "+ 5"
            bordered: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            enabled: root.available && !root.busy
            onClicked: root.setBrightness(root.brightness + 5)
          }
        }

        PanelSectionHeader {
          text: "TEMPERATURE"
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        Row {
          width: parent.width
          spacing: Style.space(8)

          Button {
            width: (parent.width - parent.spacing * 2) / 3
            text: "Warmer"
            bordered: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            enabled: root.available && !root.busy
            onClicked: root.setKelvin(root.kelvin - 200)
          }
          Button {
            width: (parent.width - parent.spacing * 2) / 3
            text: root.available ? root.kelvin + " K" : "—"
            bordered: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            enabled: false
          }
          Button {
            width: (parent.width - parent.spacing * 2) / 3
            text: "Cooler"
            bordered: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            enabled: root.available && !root.busy
            onClicked: root.setKelvin(root.kelvin + 200)
          }
        }

        PanelSectionHeader {
          text: "SCENES"
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        Row {
          width: parent.width
          spacing: Style.space(6)

          Repeater {
            model: ["night", "warm", "studio", "daylight"]
            Button {
              required property string modelData
              width: (content.width - 18) / 4
              text: modelData.charAt(0).toUpperCase() + modelData.slice(1)
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              enabled: root.available && !root.busy
              onClicked: root.setScene(modelData)
            }
          }
        }

        Text {
          visible: root.feedback !== ""
          width: parent.width
          text: root.feedback
          color: Qt.darker(root.foreground, 1.35)
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        Row {
          width: parent.width
          spacing: Style.space(8)

          Button {
            width: (parent.width - parent.spacing) / 2
            text: "Identify"
            bordered: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            enabled: root.available && !root.busy
            onClicked: root.identify()
          }
          Button {
            width: (parent.width - parent.spacing) / 2
            text: "Open Luma"
            bordered: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            enabled: !root.busy
            onClicked: {
              root.close()
              root.launchLuma()
            }
          }
        }
      }
    }
  }
}
