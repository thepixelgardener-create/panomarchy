import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// The multimonitor editor: every monitor where Hyprland puts it, each showing
// the picture it has now. Drag a picture to move it, scroll to zoom, pick each
// screen's role. The desktop behind follows every change as it happens; the
// settings file is written when a gesture ends.
//
// Open it with: omarchy-shell shell toggle thepixelgardener.multimonitor-background
// or a middle click on the desktop.
Item {
  id: root

  property var shell: null
  property var manifest: null
  property bool opened: false
  property string selected: ""
  property bool dirty: false

  readonly property string pluginId: "thepixelgardener.multimonitor-background"
  // The shell hands a panel its plugin's service when it loads it.
  property var service: null
  onShellChanged: if (!service && shell && typeof shell.serviceFor === "function") service = shell.serviceFor(pluginId)

  readonly property color onScrim: "white"
  readonly property color onScrimDim: Qt.rgba(1, 1, 1, 0.6)
  readonly property color accent: Commons.Color.accent

  function open(payloadJson) {
    opened = true
    if (service) service.refreshMonitors()
    if (!screenByName(selected)) selected = service && service.mainScreen ? service.mainScreen.name : ""
  }

  // Host-initiated close (`shell hide`).
  function close() {
    commit()
    opened = false
  }

  // Esc, Done and the scrim go through the host so its open-panel state stays right.
  function dismiss() {
    commit()
    if (shell && typeof shell.hide === "function" && shell.hide(pluginId)) return
    opened = false
  }

  function commit() {
    commitTimer.stop()
    if (dirty && service) service.persistConfig()
    dirty = false
  }

  function screenByName(name) {
    for (var i = 0; i < Quickshell.screens.length; i++) {
      if (Quickshell.screens[i].name === name) return Quickshell.screens[i]
    }
    return null
  }

  function settingsOf(name) {
    return service ? service.screenConfig(name) : {}
  }

  function numberSetting(name, key, fallback) {
    var value = settingsOf(name)[key]
    return value !== undefined && isFinite(Number(value)) ? Number(value) : fallback
  }

  // Sets x, y and scale; the neutral value removes the setting. A drag
  // defers writing the file until it ends.
  function setPlacement(name, values, deferWrite) {
    if (!service || !name) return
    var clean = {}
    if (values.x !== undefined) clean.x = Math.round(values.x) === 0 ? undefined : Math.round(values.x)
    if (values.y !== undefined) clean.y = Math.round(values.y) === 0 ? undefined : Math.round(values.y)
    if (values.scale !== undefined) {
      var scale = Math.round(Math.max(0.25, Math.min(4, values.scale)) * 1000) / 1000
      clean.scale = scale === 1 ? undefined : scale
    }
    service.saveScreenSettings(name, clean, deferWrite)
    if (deferWrite) dirty = true
  }

  function nudge(name, dx, dy) {
    setPlacement(name, { x: numberSetting(name, "x", 0) + dx, y: numberSetting(name, "y", 0) + dy }, true)
    commitTimer.restart()
  }

  function zoom(name, factor) {
    setPlacement(name, { scale: numberSetting(name, "scale", 1) * factor }, true)
    commitTimer.restart()
  }

  function resetScreen(name) {
    if (!service || !name) return
    service.saveScreenSettings(name, { x: undefined, y: undefined, scale: undefined }, false)
  }

  function setRole(name, role) {
    if (!service || !name) return
    service.saveScreenSetting(name, "role", role === "auto" ? undefined : role, false)
  }

  function cycleSelection(step) {
    var names = []
    for (var i = 0; i < Quickshell.screens.length; i++) names.push(Quickshell.screens[i].name)
    if (!names.length) return
    var index = names.indexOf(selected)
    selected = names[((index < 0 ? 0 : index + step) % names.length + names.length) % names.length]
  }

  function fileName(path) {
    path = String(path || "")
    return path.substring(path.lastIndexOf("/") + 1)
  }

  // Writes the file a moment after the last nudge or scroll step.
  Timer {
    id: commitTimer
    interval: 600
    repeat: false
    onTriggered: root.commit()
  }

  OverlayWindow {
    id: window
    shown: root.opened
    WlrLayershell.namespace: "multimonitor-background-editor"

    onShownChanged: if (shown) Qt.callLater(function() { keys.forceActiveFocus() })

    Rectangle {
      anchors.fill: parent
      color: Qt.rgba(0, 0, 0, 0.72)
      MouseArea {
        anchors.fill: parent
        onClicked: root.dismiss()
      }
    }

    Item {
      id: keys
      anchors.fill: parent
      focus: true

      Keys.onPressed: function(event) {
        var step = (event.modifiers & Qt.ShiftModifier) ? 10 : 1
        if (event.key === Qt.Key_Escape || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) root.dismiss()
        else if (event.key === Qt.Key_Left) root.nudge(root.selected, -step, 0)
        else if (event.key === Qt.Key_Right) root.nudge(root.selected, step, 0)
        else if (event.key === Qt.Key_Up) root.nudge(root.selected, 0, -step)
        else if (event.key === Qt.Key_Down) root.nudge(root.selected, 0, step)
        else if (event.key === Qt.Key_Plus || event.key === Qt.Key_Equal) root.zoom(root.selected, step === 10 ? 1.1 : 1.01)
        else if (event.key === Qt.Key_Minus) root.zoom(root.selected, step === 10 ? 1 / 1.1 : 1 / 1.01)
        else if (event.key === Qt.Key_Tab) root.cycleSelection(1)
        else if (event.key === Qt.Key_Backtab) root.cycleSelection(-1)
        else if (event.key === Qt.Key_0) root.resetScreen(root.selected)
        else return
        event.accepted = true
      }

      Rectangle {
        id: card
        anchors.centerIn: parent
        width: Math.min(parent.width - Style.space(48), Style.space(1500))
        height: Math.min(parent.height - Style.space(48), Style.space(820))
        radius: Style.space(10)
        color: Commons.Color.popups.background
        border.color: Commons.Color.popups.border
        border.width: Math.max(1, Style.space(2))

        // On a narrow screen, such as a portrait one, the settings go below
        // the monitors instead of beside them.
        readonly property bool narrow: width < Style.space(1100)

        // Clicks on the card must not reach the scrim.
        MouseArea { anchors.fill: parent }

        Text {
          id: title
          anchors { left: parent.left; top: parent.top; leftMargin: Style.space(24); topMargin: Style.space(20) }
          text: "Multimonitor Background"
          color: Commons.Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.body * 1.35
          font.bold: true
        }

        Text {
          anchors { left: title.right; baseline: title.baseline; leftMargin: Style.space(14) }
          text: root.service ? root.fileName(root.service.displayedBackground) : ""
          color: Qt.rgba(Commons.Color.foreground.r, Commons.Color.foreground.g, Commons.Color.foreground.b, 0.6)
          font.family: Style.font.family
          font.pixelSize: Style.font.body
        }

        // The monitors, laid out as Hyprland places them.
        Item {
          id: canvas
          anchors {
            left: parent.left; top: title.bottom
            bottom: card.narrow ? inspector.top : help.top
            right: card.narrow ? parent.right : inspector.left
            margins: Style.space(24)
          }

          readonly property var bounds: {
            var minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity
            for (var i = 0; i < Quickshell.screens.length; i++) {
              var s = Quickshell.screens[i]
              minX = Math.min(minX, s.x); minY = Math.min(minY, s.y)
              maxX = Math.max(maxX, s.x + s.width); maxY = Math.max(maxY, s.y + s.height)
            }
            return isFinite(minX) ? { x: minX, y: minY, w: maxX - minX, h: maxY - minY } : { x: 0, y: 0, w: 1, h: 1 }
          }
          // Canvas pixels per logical pixel, leaving room around the screens for
          // the outlines of pictures that reach past them.
          readonly property real s: Math.max(0.01, Math.min(width / (bounds.w * 1.12), height / (bounds.h * 1.12)))
          readonly property real ox: (width - bounds.w * s) / 2 - bounds.x * s
          readonly property real oy: (height - bounds.h * s) / 2 - bounds.y * s

          Repeater {
            model: Quickshell.screens

            delegate: Item {
              id: monitor
              required property var modelData
              readonly property string name: modelData.name
              readonly property var view: root.service ? root.service.screenView(name) : null
              readonly property string role: root.service ? (root.service.screenRoles[name] || "main") : ""
              readonly property bool isSelected: root.selected === name
              readonly property real s: canvas.s

              x: canvas.ox + modelData.x * s
              y: canvas.oy + modelData.y * s
              width: modelData.width * s
              height: modelData.height * s
              z: isSelected ? 2 : 1

              // Where this screen's picture reaches, past its edges too.
              Rectangle {
                visible: !!monitor.view
                x: monitor.view ? monitor.view.x * monitor.s : 0
                y: monitor.view ? monitor.view.y * monitor.s : 0
                width: monitor.view ? monitor.view.w * monitor.s : 0
                height: monitor.view ? monitor.view.h * monitor.s : 0
                color: "transparent"
                border.color: monitor.isSelected ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.55) : Qt.rgba(1, 1, 1, 0.14)
                border.width: 1
              }

              Item {
                anchors.fill: parent
                clip: true

                Rectangle { anchors.fill: parent; color: "black" }

                // The blurred fill the desktop shows where a placed panel stops.
                Image {
                  anchors.fill: parent
                  visible: !!monitor.view && !monitor.view.covers
                  source: visible ? root.service.imageUrl(monitor.view.file) : ""
                  sourceSize.width: 480
                  fillMode: Image.PreserveAspectCrop
                  asynchronous: true
                  opacity: 0.35
                }

                Image {
                  x: monitor.view ? monitor.view.x * monitor.s : 0
                  y: monitor.view ? monitor.view.y * monitor.s : 0
                  width: monitor.view ? monitor.view.w * monitor.s : 0
                  height: monitor.view ? monitor.view.h * monitor.s : 0
                  source: monitor.view ? root.service.imageUrl(monitor.view.file) : ""
                  sourceSize.width: 960
                  fillMode: Image.PreserveAspectCrop
                  asynchronous: true
                  smooth: true
                  mipmap: true
                }
              }

              Rectangle {
                anchors.fill: parent
                color: "transparent"
                border.color: monitor.isSelected ? root.accent : Qt.rgba(1, 1, 1, 0.45)
                border.width: monitor.isSelected ? Style.space(3) : 1
              }

              Rectangle {
                anchors { left: parent.left; bottom: parent.bottom; margins: Style.space(6) }
                width: label.implicitWidth + Style.space(12)
                height: label.implicitHeight + Style.space(6)
                radius: Style.space(4)
                color: Qt.rgba(0, 0, 0, 0.6)
                Text {
                  id: label
                  anchors.centerIn: parent
                  text: monitor.name + " · " + monitor.role
                  color: root.onScrim
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body * 0.85
                }
              }

              MouseArea {
                id: drag
                anchors.fill: parent
                acceptedButtons: Qt.LeftButton
                cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                property real startX: 0
                property real startY: 0
                property real fromX: 0
                property real fromY: 0

                onPressed: function(mouse) {
                  root.selected = monitor.name
                  keys.forceActiveFocus()
                  startX = mouse.x
                  startY = mouse.y
                  fromX = root.numberSetting(monitor.name, "x", 0)
                  fromY = root.numberSetting(monitor.name, "y", 0)
                }
                onPositionChanged: function(mouse) {
                  if (!pressed) return
                  root.setPlacement(monitor.name, {
                    x: fromX + (mouse.x - startX) / monitor.s,
                    y: fromY + (mouse.y - startY) / monitor.s
                  }, true)
                }
                onReleased: root.commit()
                onDoubleClicked: root.resetScreen(monitor.name)
                onWheel: function(wheel) {
                  root.selected = monitor.name
                  root.zoom(monitor.name, wheel.angleDelta.y > 0 ? 1.02 : 1 / 1.02)
                }
              }
            }
          }
        }

        // The selected screen's settings and the global ones.
        Column {
          id: inspector
          anchors {
            top: card.narrow ? undefined : title.bottom
            right: parent.right
            bottom: help.top
            margins: Style.space(24)
          }
          width: card.narrow ? card.width - Style.space(48) : Style.space(330)
          spacing: Style.space(14)

          readonly property var screenObj: root.screenByName(root.selected)
          readonly property var settings: root.service ? root.service.screenConfig(root.selected) : {}

          Text {
            text: inspector.screenObj ? root.selected : "No screen"
            color: Commons.Color.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.body * 1.2
            font.bold: true
          }

          Text {
            width: parent.width
            wrapMode: Text.Wrap
            visible: !!inspector.screenObj
            text: {
              var s = inspector.screenObj
              if (!s || !root.service) return ""
              var mm = root.service.mmPerPixel(s)
              return (s.model ? s.model + "\n" : "") + s.width + " × " + s.height + " at " + s.x + ", " + s.y
                + (s.devicePixelRatio !== 1 ? ", scale " + s.devicePixelRatio : "")
                + (mm > 0 ? "\n" + mm.toFixed(3) + " mm per pixel" : "")
            }
            color: Qt.rgba(Commons.Color.foreground.r, Commons.Color.foreground.g, Commons.Color.foreground.b, 0.7)
            font.family: Style.font.family
            font.pixelSize: Style.font.body * 0.9
          }

          SectionLabel { text: "Shows" }
          ButtonGroup {
            options: [
              { value: "auto", label: "Auto" },
              { value: "main", label: "Main" },
              { value: "left", label: "Left" },
              { value: "right", label: "Right" },
              { value: "wallpaper", label: "Wallpaper" }
            ]
            value: root.service && root.selected ? (root.service.configuredRole(root.selected) || "auto") : "auto"
            onChanged: function(value) { root.setRole(root.selected, value) }
          }

          SectionLabel { text: "Position and size" }
          Text {
            text: {
              var x = root.numberSetting(root.selected, "x", 0)
              var y = root.numberSetting(root.selected, "y", 0)
              var scale = root.numberSetting(root.selected, "scale", 1)
              var auto = root.service && inspector.screenObj ? root.service.autoScaleFor(inspector.screenObj) : 1
              return "x " + x + "   y " + y + "   zoom ×" + scale.toFixed(3)
                + (Math.abs(auto - 1) >= 0.001 ? "\nautoscale ×" + auto.toFixed(3) : "")
            }
            color: Commons.Color.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.body
          }
          Row {
            spacing: Style.space(8)
            Button { text: "−"; bordered: true; onClicked: root.zoom(root.selected, 1 / 1.02) }
            Button { text: "+"; bordered: true; onClicked: root.zoom(root.selected, 1.02) }
            Button { text: "Reset screen"; bordered: true; onClicked: root.resetScreen(root.selected) }
          }

          SectionLabel { text: "Autoscale: same size on every screen" }
          ButtonGroup {
            options: [{ value: "on", label: "On" }, { value: "off", label: "Off" }]
            value: root.service && root.service.autoscale ? "on" : "off"
            onChanged: function(value) { if (root.service) root.service.setAutoscale(value === "on") }
          }

          Row {
            spacing: Style.space(8)
            Button { text: "Reset all"; bordered: true; onClicked: if (root.service) root.service.resetScreenSettings("") }
            Button { text: "Done"; bordered: true; onClicked: root.dismiss() }
          }
        }

        Text {
          id: help
          anchors { left: parent.left; right: parent.right; bottom: parent.bottom; margins: Style.space(20) }
          wrapMode: Text.Wrap
          horizontalAlignment: Text.AlignHCenter
          text: "Drag a picture to move it · scroll to zoom · double-click to reset · arrows nudge 1 px, with Shift 10 · + and − zoom · Tab picks the next screen · Esc closes"
          color: Qt.rgba(Commons.Color.foreground.r, Commons.Color.foreground.g, Commons.Color.foreground.b, 0.55)
          font.family: Style.font.family
          font.pixelSize: Style.font.body * 0.85
        }
      }
    }
  }

  component SectionLabel: Text {
    color: Qt.rgba(Commons.Color.foreground.r, Commons.Color.foreground.g, Commons.Color.foreground.b, 0.6)
    font.family: Style.font.family
    font.pixelSize: Style.font.body * 0.8
    font.capitalization: Font.AllUppercase
    font.letterSpacing: 1
  }
}
