import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Owelk.Ui

// A settings section: a small heading, rows on a rounded card, a short note under it.
ColumnLayout {
    id: root
    property string title: ""
    property string note: ""
    property color noteColor: Theme.textTertiary
    default property alias rows: card.content
    Layout.fillWidth: true
    spacing: 6
    Label {
        visible: root.title.length > 0
        leftPadding: 10
        text: root.title
        font.pixelSize: Theme.fontSmall
        font.weight: Font.DemiBold
        color: Theme.textSecondary
    }
    ListGroup { id: card; Layout.fillWidth: true; spacing: 0 }
    Label {
        visible: root.note.length > 0
        Layout.fillWidth: true
        leftPadding: 10; rightPadding: 10
        text: root.note
        wrapMode: Text.Wrap
        font.pixelSize: Theme.fontCaption
        color: root.noteColor
        lineHeight: 1.15
    }
}
