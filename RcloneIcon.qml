import QtQuick
import qs.Commons
import qs.Ui

// The cloud mark, in the bar's own visual language.
//
// STROKED, NOT FILLED. The first version used Font Awesome's solid cloud
// (U+F0C2) and it was the heaviest thing on the bar: every neighbour -- the
// bluetooth mark, the globe, the Wi-Fi arcs, the WireGuard ouroboros -- is a
// stroked outline, so a solid mass of foreground-coloured pixels read as both
// bolder and lighter than everything beside it. Material's cloud-outline
// carries the same silhouette at the neighbours' stroke weight.
//
// The disconnected state uses cloud-off-outline rather than a strike drawn on
// top. A struck-through Rectangle is what WireGuardIcon has to do because no
// glyph carries its shape; here the font already has the struck cloud, and the
// designed one sits on the stroke properly where a hand-drawn bar does not.
//
// Shape carries the state and colour only confirms it: the mark changes for
// disconnected and for activity, and the badge alone is ever urgent. A widget
// that signals only with colour says nothing in a screenshot and nothing to a
// colourblind reader.
Item {
  id: root

  property real iconSize: Style.font.icon
  property color color: Color.foreground
  property color badgeColor: Color.urgent

  // Not carrying data: signed out, or deliberately stopped.
  property bool disconnected: false
  // A genuine fault. The only thing here that is ever urgent-coloured.
  property bool warning: false
  // "" | "up" | "down" -- a small arrow in the cloud's open interior.
  property string activity: ""

  // Material Design Icons live above the BMP, so they need a code point rather
  // than a \u escape: U+F0163 cloud-outline, U+F0164 cloud-off-outline.
  readonly property string cloudGlyph: String.fromCodePoint(root.disconnected ? 0xF0164 : 0xF0163)

  width: iconSize
  height: iconSize
  implicitWidth: iconSize
  implicitHeight: iconSize

  OpticalGlyph {
    anchors.fill: parent
    text: root.cloudGlyph
    fontFamily: Style.font.family
    fontSize: root.iconSize
    color: root.color
  }

  // Inside the cloud, not hung off its corner: at bar size a corner arrow
  // reads as debris falling off the mark, while the outline's hollow interior
  // is exactly the space an arrow wants.
  Text {
    visible: root.activity !== "" && !root.disconnected
    anchors.centerIn: parent
    anchors.verticalCenterOffset: Math.round(root.iconSize * 0.08)
    text: root.activity === "down" ? "" : ""
    color: root.color
    font.family: Style.font.family
    font.pixelSize: Math.max(6, Math.round(root.iconSize * 0.42))
  }

  BorderSurface {
    visible: root.warning
    width: Math.max(7, parent.width * 0.42)
    height: width
    radius: width / 2
    color: root.badgeColor
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    borderSpec: Border.flat(Color.popups.background, 1)

    Text {
      anchors.centerIn: parent
      text: "!"
      color: Color.background
      font.family: Style.font.family
      font.pixelSize: Math.max(6, parent.height * 0.72)
      font.bold: true
    }
  }
}
