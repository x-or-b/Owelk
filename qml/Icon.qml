import QtQuick
import Owelk.Ui
import "Icons.js" as Icons

// One glyph from the icon font: same stroke everywhere, colored by the theme.
Text {
    property string name
    property int size: Theme.iconSize
    text: Icons.glyph(name)
    font.family: Theme.iconFont
    font.pixelSize: size
    color: Theme.icon
    horizontalAlignment: Text.AlignHCenter
    verticalAlignment: Text.AlignVCenter
    Accessible.ignored: true
}
