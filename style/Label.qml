import QtQuick
import QtQuick.Templates as T
import Owelk.Ui

// Text that is cut off shows all of it on hover. The hover handler only runs while truncated.
T.Label {
    id: control
    color: control.palette.windowText
    linkColor: Theme.accent
    font.pixelSize: Theme.fontBody
    HoverHandler { id: cut; enabled: control.truncated }
    T.ToolTip.visible: cut.hovered && control.truncated
    T.ToolTip.delay: 500
    T.ToolTip.text: control.text
}
