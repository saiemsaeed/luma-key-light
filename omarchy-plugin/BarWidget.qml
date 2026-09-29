import QtQuick
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "io.github.saiemsaeed.luma"

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item
    ? panelLoader.item.popoutSwitchClosing === true
    : false
  readonly property bool available: panelLoader.item ? panelLoader.item.available : false
  readonly property bool lightOn: panelLoader.item ? panelLoader.item.lightOn : false

  function injectPanel() {
    if (!panelLoader.item) return
    panelLoader.item.bar = root.bar
    panelLoader.item.settings = root.settings
    panelLoader.item.anchorItem = button
    panelLoader.item.hostWidget = root
  }

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function toggle() { if (panelLoader.item) panelLoader.item.toggle() }
  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰛨"
    active: root.lightOn
    tooltipText: !root.available
      ? "Luma — light unavailable"
      : (root.lightOn ? "Luma — light on" : "Luma — light off")
    onPressed: function(buttonCode) {
      if (!panelLoader.item) return
      if (buttonCode === Qt.MiddleButton) panelLoader.item.togglePower()
      else if (buttonCode === Qt.RightButton) panelLoader.item.launchLuma()
      else root.toggle()
    }
  }
}
