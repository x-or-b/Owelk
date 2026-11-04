import QtQuick
import QtQuick.Shapes
import Owelk.Ui
import "Icons.js" as Icons

// One glyph from the icon font: same stroke everywhere, colored by the theme. Undo is the font's turning arrow and
// redo the same arrow mirrored; the eraser, not in the font yet, is drawn in Lucide's 24-unit box and 2-unit stroke.
Text {
    id: root
    property string name
    property int size: Theme.iconSize
    readonly property var drawn: ({
        erase: "M21 21H8a2 2 0 0 1-1.42-.587l-3.994-3.999a2 2 0 0 1 0-2.828l10-10a2 2 0 0 1 2.829 0l5.999 6a2 2 0 0 1 0 2.828L12.834 21M5.082 11.09l8.828 8.828"
    })
    readonly property string path: drawn[name] || ""
    text: path.length ? "" : Icons.glyph(name === "undo" || name === "redo" ? "restore" : name)
    font.family: Theme.iconFont
    font.pixelSize: size
    color: Theme.icon
    horizontalAlignment: Text.AlignHCenter
    verticalAlignment: Text.AlignVCenter
    Accessible.ignored: true
    transform: Scale { origin.x: root.width / 2; xScale: root.name === "redo" ? -1 : 1 }
    Shape {
        visible: root.path.length > 0
        anchors.centerIn: parent
        width: root.size; height: root.size
        preferredRendererType: Shape.CurveRenderer
        ShapePath {
            strokeColor: root.color
            strokeWidth: root.size / 12
            fillColor: "transparent"
            capStyle: ShapePath.RoundCap
            joinStyle: ShapePath.RoundJoin
            scale: Qt.size(root.size / 24, root.size / 24)
            PathSvg { path: root.path || "M0 0" }
        }
    }
}
