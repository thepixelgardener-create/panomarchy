import QtQuick
import qs.Commons
import qs.Ui

// The bar icon: opens and closes the editor.
BarWidget {
  id: root
  moduleName: "thepixelgardener.panomarchy"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // The glyph only holds the slot; the drawn icon is what shows.
    text: "󰍺"
    labelVisible: false
    fontSize: Style.bar.iconFont
    fixedWidth: vertical ? -1 : Math.max(Style.bar.iconSlot, icon.width + Style.space(10))
    fixedHeight: vertical ? Style.bar.iconSlot : -1
    tooltipText: "Panomarchy"

    SpanIcon {
      id: icon
      x: Math.round((parent.width - width) / 2)
      y: Math.round((parent.height - height) / 2)
      size: Style.bar.iconSize || Style.bar.iconFont
      foreground: button.foreground
      scale: button.pressScale || 1
    }

    onPressed: function(mouseButton) {
      if (mouseButton === Qt.LeftButton && root.bar)
        root.bar.run("omarchy-shell shell toggle thepixelgardener.panomarchy '{}'")
    }
  }
}
