import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// The multimonitor editor: every monitor where Hyprland puts it, each showing
// the picture it has now, and a box around what is being adjusted:
//
//   Whole scene  the picture across all screens; the side screens follow
//                the main one
//   One screen   a single screen's picture, for when autoscale does not
//                quite match that monitor; it is sized about the seam it
//                shares with the main screen, so it stays attached there
//
// Drag anywhere to move it, drag a corner of the box to resize it with the
// opposite corner held, scroll to zoom about the pointer. The desktop behind
// follows every change as it happens; the settings file is written when a
// gesture ends.
//
// Open it from the bar icon, with a middle click on the desktop, or with
// omarchy-shell shell toggle thepixelgardener.multimonitor-background
Item {
  id: root

  property var shell: null
  property var manifest: null
  // The shell hands a panel its plugin's service when it loads it.
  property var service: null
  onShellChanged: if (!service && shell && typeof shell.serviceFor === "function") service = shell.serviceFor(pluginId)

  property bool opened: false
  property string mode: "scene"
  property string selected: ""
  property bool dirty: false
  property bool gesturing: false

  readonly property string pluginId: "thepixelgardener.multimonitor-background"
  readonly property string mainName: service && service.mainScreen ? service.mainScreen.name : ""
  readonly property color accent: Commons.Color.accent
  readonly property color fg: Commons.Color.foreground
  readonly property color fgDim: Qt.rgba(fg.r, fg.g, fg.b, 0.62)

  function open(payloadJson) {
    opened = true
    if (service) service.refreshMonitors()
    if (!screenByName(selected)) selected = mainName
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

  function screenAt(point) {
    for (var i = 0; i < Quickshell.screens.length; i++) {
      var s = Quickshell.screens[i]
      if (point.x >= s.x && point.x < s.x + s.width && point.y >= s.y && point.y < s.y + s.height) return s.name
    }
    return ""
  }

  function fileName(path) {
    path = String(path || "")
    return path.substring(path.lastIndexOf("/") + 1)
  }

  // The target being adjusted: the whole scene or the selected screen.
  // Its move and size, the point its size pivots on and its box are all in
  // global logical pixels, the coordinates Hyprland lays monitors out in.
  function targetTransform() {
    if (!service) return { scale: 1, x: 0, y: 0 }
    return service.transformOf(mode === "scene" ? service.sceneConfig() : service.screenConfig(selected))
  }

  function targetAnchor() {
    if (!service) return { x: 0, y: 0 }
    return mode === "scene" ? service.sceneAnchor() : service.screenAnchor(selected)
  }

  function targetBox() {
    if (!service) return null
    if (mode === "scene") return service.mainWallpaperRect(service.displayedBackground)
    var screen = screenByName(selected)
    var view = service.screenView(selected)
    return screen && view ? { x: screen.x + view.x, y: screen.y + view.y, w: view.w, h: view.h } : null
  }

  function applyTransform(t, deferWrite) {
    if (!service) return
    var scale = Math.round(Math.max(0.2, Math.min(5, t.scale)) * 1000) / 1000
    var clean = {
      x: Math.round(t.x) === 0 ? undefined : Math.round(t.x),
      y: Math.round(t.y) === 0 ? undefined : Math.round(t.y),
      scale: scale === 1 ? undefined : scale
    }
    if (mode === "scene") service.saveScene(clean, deferWrite)
    else if (selected) service.saveScreenSettings(selected, clean, deferWrite)
    if (deferWrite) dirty = true
  }

  // The move and size that grows or shrinks by `factor` while the global
  // point `fixed` stays where it is on screen.
  function scaledAbout(from, anchor, fixed, factor) {
    var scale = Math.max(0.2, Math.min(5, from.scale * factor))
    var px = anchor.x + (fixed.x - anchor.x - from.x) / from.scale
    var py = anchor.y + (fixed.y - anchor.y - from.y) / from.scale
    return { scale: scale, x: fixed.x - anchor.x - (px - anchor.x) * scale, y: fixed.y - anchor.y - (py - anchor.y) * scale }
  }

  function zoomAt(point, factor) {
    applyTransform(scaledAbout(targetTransform(), targetAnchor(), point, factor), true)
    commitTimer.restart()
  }

  function zoomCentre(factor) {
    var box = targetBox()
    if (box) zoomAt({ x: box.x + box.w / 2, y: box.y + box.h / 2 }, factor)
  }

  function nudge(dx, dy) {
    var t = targetTransform()
    applyTransform({ scale: t.scale, x: t.x + dx, y: t.y + dy }, true)
    commitTimer.restart()
  }

  function resetTarget() {
    if (!service) return
    var neutral = { x: undefined, y: undefined, scale: undefined }
    if (mode === "scene") service.saveScene(neutral, false)
    else if (selected) service.saveScreenSettings(selected, neutral, false)
  }

  function selectScreen(name) {
    mode = "screen"
    selected = name
  }

  function cycleScreen(step) {
    var names = []
    for (var i = 0; i < Quickshell.screens.length; i++) names.push(Quickshell.screens[i].name)
    if (!names.length) return
    var index = names.indexOf(selected)
    selectScreen(names[((index < 0 ? 0 : index + step) % names.length + names.length) % names.length])
  }

  function describe(t) {
    return "size ×" + t.scale.toFixed(3) + "   moved " + Math.round(t.x) + ", " + Math.round(t.y)
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
        else if (event.key === Qt.Key_Left) root.nudge(-step, 0)
        else if (event.key === Qt.Key_Right) root.nudge(step, 0)
        else if (event.key === Qt.Key_Up) root.nudge(0, -step)
        else if (event.key === Qt.Key_Down) root.nudge(0, step)
        else if (event.key === Qt.Key_Plus || event.key === Qt.Key_Equal) root.zoomCentre(step === 10 ? 1.1 : 1.01)
        else if (event.key === Qt.Key_Minus) root.zoomCentre(step === 10 ? 1 / 1.1 : 1 / 1.01)
        else if (event.key === Qt.Key_Tab) root.cycleScreen(1)
        else if (event.key === Qt.Key_Backtab) root.cycleScreen(-1)
        else if (event.key === Qt.Key_S) root.mode = "scene"
        else if (event.key === Qt.Key_0) root.resetTarget()
        else return
        event.accepted = true
      }

      Rectangle {
        id: card
        anchors.centerIn: parent
        width: Math.min(parent.width - Style.space(48), Style.space(1500))
        height: Math.min(parent.height - Style.space(48), Style.space(860))
        radius: Style.space(10)
        color: Commons.Color.popups.background
        border.color: Commons.Color.popups.border
        border.width: Math.max(1, Style.space(2))

        // Clicks on the card must not reach the scrim.
        MouseArea { anchors.fill: parent }

        Text {
          id: title
          anchors { left: parent.left; top: parent.top; leftMargin: Style.space(24); topMargin: Style.space(20) }
          text: "Multimonitor Background"
          color: root.fg
          font.family: Style.font.family
          font.pixelSize: Style.font.body * 1.35
          font.bold: true
        }

        Text {
          anchors { left: title.right; baseline: title.baseline; leftMargin: Style.space(14) }
          text: root.service ? root.fileName(root.service.displayedBackground) : ""
          color: root.fgDim
          font.family: Style.font.family
          font.pixelSize: Style.font.body
        }

        // The monitors, laid out as Hyprland places them.
        Item {
          id: canvas
          anchors {
            left: parent.left; top: title.bottom; bottom: help.top; right: inspector.left
            margins: Style.space(24)
          }
          clip: true

          // The area shown: every monitor, and the box being adjusted as far
          // as it stays near them. It holds still during a gesture, so the
          // picture does not slide away under the pointer.
          readonly property var liveBounds: {
            var minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity
            for (var i = 0; i < Quickshell.screens.length; i++) {
              var s = Quickshell.screens[i]
              minX = Math.min(minX, s.x); minY = Math.min(minY, s.y)
              maxX = Math.max(maxX, s.x + s.width); maxY = Math.max(maxY, s.y + s.height)
            }
            if (!isFinite(minX)) return { x: 0, y: 0, w: 1, h: 1 }
            var box = root.targetBox()
            if (box) {
              var padX = (maxX - minX) * 0.35, padY = (maxY - minY) * 0.35
              minX = Math.min(minX, Math.max(box.x, minX - padX))
              minY = Math.min(minY, Math.max(box.y, minY - padY))
              maxX = Math.max(maxX, Math.min(box.x + box.w, maxX + padX))
              maxY = Math.max(maxY, Math.min(box.y + box.h, maxY + padY))
            }
            return { x: minX, y: minY, w: maxX - minX, h: maxY - minY }
          }
          property var bounds: ({ x: 0, y: 0, w: 1, h: 1 })
          Binding on bounds {
            when: !root.gesturing
            value: canvas.liveBounds
            restoreMode: Binding.RestoreNone
          }

          readonly property real s: Math.max(0.01, Math.min(width / (bounds.w * 1.08), height / (bounds.h * 1.08)))
          readonly property real ox: (width - bounds.w * s) / 2 - bounds.x * s
          readonly property real oy: (height - bounds.h * s) / 2 - bounds.y * s

          function toGlobal(px, py) {
            return { x: (px - ox) / s, y: (py - oy) / s }
          }

          // The box being adjusted, in canvas pixels.
          readonly property var boxCanvas: {
            var box = root.targetBox()
            return box ? { x: ox + box.x * s, y: oy + box.y * s, w: box.w * s, h: box.h * s } : null
          }

          // Every screen's picture where it reaches past its screen, faintly.
          Repeater {
            model: Quickshell.screens
            delegate: Image {
              required property var modelData
              readonly property var view: root.service ? root.service.screenView(modelData.name) : null
              visible: !!view
              opacity: 0.22
              x: view ? canvas.ox + (modelData.x + view.x) * canvas.s : 0
              y: view ? canvas.oy + (modelData.y + view.y) * canvas.s : 0
              width: view ? view.w * canvas.s : 0
              height: view ? view.h * canvas.s : 0
              source: view ? root.service.imageUrl(view.file) : ""
              sourceSize.width: 960
              fillMode: Image.PreserveAspectCrop
              asynchronous: true
            }
          }

          // Every screen with the part of its picture it shows.
          Repeater {
            model: Quickshell.screens
            delegate: Item {
              id: monitor
              required property var modelData
              readonly property string name: modelData.name
              readonly property var view: root.service ? root.service.screenView(name) : null
              readonly property string role: root.service ? (root.service.screenRoles[name] || "main") : ""
              readonly property bool isSelected: root.mode === "screen" && root.selected === name

              x: canvas.ox + modelData.x * canvas.s
              y: canvas.oy + modelData.y * canvas.s
              width: modelData.width * canvas.s
              height: modelData.height * canvas.s

              Item {
                anchors.fill: parent
                clip: true
                Rectangle { anchors.fill: parent; color: "black" }
                Image {
                  x: monitor.view ? monitor.view.x * canvas.s : 0
                  y: monitor.view ? monitor.view.y * canvas.s : 0
                  width: monitor.view ? monitor.view.w * canvas.s : 0
                  height: monitor.view ? monitor.view.h * canvas.s : 0
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
                border.color: monitor.isSelected ? root.accent : Qt.rgba(1, 1, 1, 0.5)
                border.width: monitor.isSelected ? Style.space(3) : 1
              }

              Rectangle {
                anchors { left: parent.left; bottom: parent.bottom; margins: Style.space(6) }
                width: label.implicitWidth + Style.space(12)
                height: label.implicitHeight + Style.space(6)
                radius: Style.space(4)
                color: Qt.rgba(0, 0, 0, 0.62)
                Text {
                  id: label
                  anchors.centerIn: parent
                  text: monitor.name + " · " + monitor.role
                  color: "white"
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body * 0.85
                }
              }
            }
          }

          // Drag to move, scroll to zoom about the pointer, double-click to
          // reset; in One screen mode a press also picks the screen under it.
          MouseArea {
            id: mover
            anchors.fill: parent
            acceptedButtons: Qt.LeftButton
            cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
            property var start: null
            property var from: null

            function finish() {
              start = null
              root.gesturing = false
              root.commit()
            }

            onPressed: function(mouse) {
              keys.forceActiveFocus()
              var point = canvas.toGlobal(mouse.x, mouse.y)
              if (root.mode === "screen") {
                var hit = root.screenAt(point)
                if (hit) root.selected = hit
              }
              root.gesturing = true
              start = point
              from = root.targetTransform()
            }
            onPositionChanged: function(mouse) {
              if (!pressed || !start) return
              var point = canvas.toGlobal(mouse.x, mouse.y)
              root.applyTransform({ scale: from.scale, x: from.x + point.x - start.x, y: from.y + point.y - start.y }, true)
            }
            onReleased: finish()
            onCanceled: finish()
            onDoubleClicked: root.resetTarget()
            onWheel: function(wheel) {
              root.zoomAt(canvas.toGlobal(wheel.x, wheel.y), Math.pow(1.05, wheel.angleDelta.y / 120))
            }
          }

          // The box being adjusted, with a handle on each corner.
          Rectangle {
            visible: !!canvas.boxCanvas
            x: canvas.boxCanvas ? canvas.boxCanvas.x : 0
            y: canvas.boxCanvas ? canvas.boxCanvas.y : 0
            width: canvas.boxCanvas ? canvas.boxCanvas.w : 0
            height: canvas.boxCanvas ? canvas.boxCanvas.h : 0
            color: "transparent"
            border.color: root.accent
            border.width: Style.space(2)
          }

          Repeater {
            model: 4
            delegate: Rectangle {
              id: handle
              required property int index
              readonly property var box: canvas.boxCanvas
              readonly property bool leftSide: index === 0 || index === 3
              readonly property bool topSide: index < 2
              visible: !!box
              width: Style.space(16)
              height: width
              radius: Style.space(3)
              color: Commons.Color.popups.background
              border.color: root.accent
              border.width: Style.space(3)
              x: box ? (leftSide ? box.x : box.x + box.w) - width / 2 : 0
              y: box ? (topSide ? box.y : box.y + box.h) - height / 2 : 0

              MouseArea {
                anchors.fill: parent
                anchors.margins: -Style.space(8)
                cursorShape: handle.index % 2 === 0 ? Qt.SizeFDiagCursor : Qt.SizeBDiagCursor
                property var fixedPoint: null
                property var startPoint: null
                property var from: null
                property var anchor: null

                function finish() {
                  from = null
                  root.gesturing = false
                  root.commit()
                }

                onPressed: function(mouse) {
                  keys.forceActiveFocus()
                  var b = root.targetBox()
                  if (!b) return
                  var corners = [{ x: b.x, y: b.y }, { x: b.x + b.w, y: b.y }, { x: b.x + b.w, y: b.y + b.h }, { x: b.x, y: b.y + b.h }]
                  startPoint = corners[handle.index]
                  fixedPoint = corners[(handle.index + 2) % 4]
                  from = root.targetTransform()
                  anchor = root.targetAnchor()
                  root.gesturing = true
                }
                onPositionChanged: function(mouse) {
                  if (!pressed || !from) return
                  var p = mapToItem(canvas, mouse.x, mouse.y)
                  var point = canvas.toGlobal(p.x, p.y)
                  var dx = startPoint.x - fixedPoint.x
                  var dy = startPoint.y - fixedPoint.y
                  var factor = ((point.x - fixedPoint.x) * dx + (point.y - fixedPoint.y) * dy) / (dx * dx + dy * dy)
                  root.applyTransform(root.scaledAbout(from, anchor, fixedPoint, Math.max(0.05, factor)), true)
                }
                onReleased: finish()
                onCanceled: finish()
              }
            }
          }
        }

        // What is being adjusted, and the settings that go with it.
        Column {
          id: inspector
          anchors { top: title.bottom; right: parent.right; bottom: help.top; margins: Style.space(24) }
          width: Style.space(340)
          spacing: Style.space(12)

          readonly property var screenObj: root.screenByName(root.selected)
          readonly property var t: root.service ? root.service.transformOf(root.mode === "scene" ? root.service.sceneConfig() : root.service.screenConfig(root.selected)) : ({ scale: 1, x: 0, y: 0 })

          SectionLabel { text: "Adjust" }
          ButtonGroup {
            options: [{ value: "scene", label: "Whole scene" }, { value: "screen", label: "One screen" }]
            value: root.mode
            onChanged: function(value) {
              root.mode = value
              if (value === "screen" && !root.screenByName(root.selected)) root.selected = root.mainName
            }
          }

          // Whole scene
          Text {
            visible: root.mode === "scene"
            width: parent.width
            wrapMode: Text.Wrap
            text: "The picture across every screen. The side screens follow the main one."
            color: root.fgDim
            font.family: Style.font.family
            font.pixelSize: Style.font.body * 0.9
          }

          // One screen
          Text {
            visible: root.mode === "screen"
            text: inspector.screenObj ? root.selected + " · " + (root.service ? root.service.screenRoles[root.selected] : "") : "Pick a screen"
            color: root.fg
            font.family: Style.font.family
            font.pixelSize: Style.font.body * 1.1
            font.bold: true
          }
          Text {
            visible: root.mode === "screen" && !!inspector.screenObj
            width: parent.width
            wrapMode: Text.Wrap
            text: {
              var s = inspector.screenObj
              if (!s || !root.service) return ""
              var mm = root.service.mmPerPixel(s)
              var auto = root.service.autoScaleFor(s)
              return (s.model ? s.model + "\n" : "") + s.width + " × " + s.height + " at " + s.x + ", " + s.y
                + (s.devicePixelRatio !== 1 ? ", scale " + s.devicePixelRatio : "")
                + (mm > 0 ? "\n" + mm.toFixed(3) + " mm per pixel" : "")
                + (Math.abs(auto - 1) >= 0.001 ? ", autoscaled ×" + auto.toFixed(3) : "")
            }
            color: root.fgDim
            font.family: Style.font.family
            font.pixelSize: Style.font.body * 0.9
          }
          SectionLabel { visible: root.mode === "screen"; text: "Shows" }
          ButtonGroup {
            visible: root.mode === "screen"
            options: [
              { value: "auto", label: "Auto" },
              { value: "main", label: "Main" },
              { value: "left", label: "Left" },
              { value: "right", label: "Right" },
              { value: "wallpaper", label: "Own" }
            ]
            value: root.service && root.selected ? (root.service.configuredRole(root.selected) || "auto") : "auto"
            onChanged: function(value) {
              if (root.service && root.selected) root.service.saveScreenSetting(root.selected, "role", value === "auto" ? undefined : value, false)
            }
          }

          SectionLabel { text: root.mode === "scene" ? "Whole scene" : "This screen" }
          Text {
            text: root.describe(inspector.t)
            color: root.fg
            font.family: Style.font.family
            font.pixelSize: Style.font.body
          }
          Row {
            spacing: Style.space(8)
            Button { text: "−"; bordered: true; onClicked: root.zoomCentre(1 / 1.02) }
            Button { text: "+"; bordered: true; onClicked: root.zoomCentre(1.02) }
            Button { text: root.mode === "scene" ? "Reset scene" : "Reset screen"; bordered: true; onClicked: root.resetTarget() }
          }

          SectionLabel { text: "Autoscale: same size on every monitor" }
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
          text: (root.mode === "scene"
                 ? "Drag to move the whole picture · drag a corner to resize it · scroll to zoom where the pointer is"
                 : "Click a screen to pick it · drag to move its picture · drag a corner to resize it, the seam stays put · scroll to zoom")
                + " · double-click resets · arrows nudge, with Shift 10 px · Tab picks a screen, S the whole scene · Esc closes"
          color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.55)
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
