import QtQuick
import QtQuick.Controls
import Owelk.Ui

// A small picture of a theme with its name under it: toolbar, sidebar, page with lines of text and an accent mark.
// For the themes in Settings › Appearance, the theme gallery, and themes made from a photo or a color. With `adding`,
// a + in place of the picture.
Item {
    id: tile
    property var seeds: ({})
    property color accent: Theme.accent
    property string name
    property bool current: false
    property url picture: ""
    property bool adding: false
    signal tapped()
    signal menuRequested()
    width: 104; height: 92
    Rectangle {
        id: preview
        width: parent.width; height: 64
        radius: Theme.radius
        color: tile.adding ? (hover.hovered ? Theme.hover : "transparent") : tile.seeds.window || "transparent"
        border.width: tile.current ? 2 : 1
        border.color: tile.current ? Theme.accent : hover.hovered ? Theme.border : Theme.separator
        clip: true
        Item {
            visible: !tile.adding
            anchors.fill: parent
            Rectangle { x: 6; y: 12; width: 24; height: parent.height - 18; radius: 3; color: tile.seeds.sidebar || "transparent" }
            Rectangle {
                x: 34; y: 12; width: parent.width - 40; height: parent.height - 18; radius: 3; color: tile.seeds.content || "transparent"
                Column {
                    x: 6; y: 7; spacing: 4
                    Repeater { model: [44, 52, 30]; Rectangle { width: modelData; height: 3; radius: 1.5; color: tile.seeds.text || "transparent"; opacity: index === 0 ? .9 : .45 } }
                }
                Rectangle { anchors.right: parent.right; anchors.bottom: parent.bottom; anchors.margins: 6; width: 14; height: 6; radius: 3; color: tile.accent }
            }
            Row { x: 6; y: 4; spacing: 3; Repeater { model: 3; Rectangle { width: 4; height: 4; radius: 2; color: tile.seeds.text || "transparent"; opacity: .25 } } }
            Image {
                visible: tile.picture.toString().length > 0
                source: tile.picture
                anchors.right: parent.right; anchors.bottom: parent.bottom; anchors.margins: 2
                width: parent.height - 8; height: width
                fillMode: Image.PreserveAspectFit
                horizontalAlignment: Image.AlignRight; verticalAlignment: Image.AlignBottom
                sourceSize: Qt.size(128, 128)
                asynchronous: true
            }
        }
        Icon { visible: tile.adding; anchors.centerIn: parent; name: "add"; color: Theme.icon }
    }
    Label {
        anchors.top: preview.bottom; anchors.topMargin: 5
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        text: tile.name
        elide: Text.ElideRight; textFormat: Text.PlainText
        font.pixelSize: Theme.fontSmall
        font.weight: tile.current ? Font.DemiBold : Font.Normal
        color: tile.current ? Theme.text : Theme.textSecondary
    }
    HoverHandler { id: hover; cursorShape: Qt.PointingHandCursor }
    TapHandler { onTapped: tile.tapped() }
    ContextTap { onRequested: tile.menuRequested() }
    Accessible.role: tile.adding ? Accessible.Button : Accessible.RadioButton
    Accessible.name: tile.adding ? tile.name : tile.name + qsTr(" theme")
}
