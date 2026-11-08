import QtQuick
import QtQuick.Shapes
import qs.Commons as Commons

// The plugin's icon: a portrait screen and two wide ones, the last a little
// lower, showing one picture between them: a surface whose horizon rises in
// the middle and runs on across the bezels. Drawn as vectors so it stays
// sharp at any scale.
Item {
  id: root

  property real size: 12
  property color foreground: Commons.Color.foreground
  property color accent: Commons.Color.accent

  readonly property real stroke: Math.max(1, Math.round(size * 0.1))
  // The screens in units of the icon's height.
  readonly property var screens: [
    { x: 0, y: 0, w: 0.38, h: 1 },
    { x: 0.48, y: 0.12, w: 0.7, h: 0.76 },
    { x: 1.28, y: 0.2, w: 0.5, h: 0.6 }
  ]
  readonly property real units: 1.78

  implicitWidth: Math.round(size * units)
  implicitHeight: size
  width: implicitWidth
  height: implicitHeight

  // The horizon's height at a point across the icon, highest in the middle.
  function horizon(u) {
    return 0.66 - 0.26 * Math.sin(Math.PI * u / units)
  }

  // The surface inside one screen: up to the horizon, down to the bottom,
  // inset by the frame, as an outline in pixels.
  function surface(box) {
    var inset = stroke / size
    var left = box.x + inset
    var right = box.x + box.w - inset
    var bottom = box.y + box.h - inset
    var points = []
    for (var i = 0; i <= 8; i++) {
      var u = left + (right - left) * i / 8
      points.push(Qt.point(u * size, Math.min(bottom, horizon(u)) * size))
    }
    points.push(Qt.point(right * size, bottom * size))
    points.push(Qt.point(left * size, bottom * size))
    points.push(points[0])
    return points
  }

  component Frame: ShapePath {
    required property var box
    strokeColor: root.foreground
    strokeWidth: root.stroke
    fillColor: "transparent"
    joinStyle: ShapePath.RoundJoin
    PathRectangle {
      x: box.x * root.size + root.stroke / 2
      y: box.y * root.size + root.stroke / 2
      width: box.w * root.size - root.stroke
      height: box.h * root.size - root.stroke
      radius: root.size * 0.08
    }
  }

  component Surface: ShapePath {
    required property var box
    strokeColor: "transparent"
    fillColor: root.accent
    PathPolyline { path: root.surface(box) }
  }

  Shape {
    anchors.fill: parent
    preferredRendererType: Shape.CurveRenderer

    Surface { box: root.screens[0] }
    Surface { box: root.screens[1] }
    Surface { box: root.screens[2] }
    Frame { box: root.screens[0] }
    Frame { box: root.screens[1] }
    Frame { box: root.screens[2] }
  }
}
