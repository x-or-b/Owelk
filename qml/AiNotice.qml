import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Owelk.Ui

// "Answer ready": a small card at the bottom right when an AI answer arrives while its thread is not
// in view. Open shows the thread, Dismiss (or a few seconds) lets it go; hovering keeps it.
Rectangle {
    id: root
    objectName: "aiNotice"
    property string threadId: ""
    property string title: ""
    property string preview: ""
    signal openRequested(string threadId)
    function show(id, heading, text) {
        threadId = id; title = heading; preview = text
        visible = true
        hideTimer.restart()
    }
    function dismiss() { visible = false; hideTimer.stop() }
    visible: false
    width: 320
    height: column.implicitHeight + 20
    radius: Theme.radiusLarge
    color: Theme.raised
    border.color: Theme.border
    z: 90
    Timer { id: hideTimer; interval: 8000; onTriggered: if (!hover.hovered) root.dismiss(); else restart() }
    HoverHandler { id: hover }
    ColumnLayout {
        id: column
        x: 12; y: 10
        width: parent.width - 24
        spacing: 4
        RowLayout {
            Layout.fillWidth: true
            spacing: 6
            Icon { name: "ai"; color: Theme.accent; size: Theme.fontBody }
            Label { Layout.fillWidth: true; text: "Answer ready"; font.weight: Font.DemiBold; color: Theme.text }
        }
        Label {
            Layout.fillWidth: true
            visible: root.title.length > 0
            text: root.title
            elide: Text.ElideRight; textFormat: Text.PlainText
            font.pixelSize: Theme.fontSmall; color: Theme.textSecondary
        }
        Label {
            Layout.fillWidth: true
            visible: root.preview.length > 0
            text: root.preview
            wrapMode: Text.Wrap; maximumLineCount: 2; elide: Text.ElideRight; textFormat: Text.PlainText
            font.pixelSize: Theme.fontSmall; color: Theme.textTertiary
        }
        RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: 4
            Item { Layout.fillWidth: true }
            Button { objectName: "aiNoticeDismiss"; text: "Dismiss"; flat: true; onClicked: root.dismiss() }
            Button { objectName: "aiNoticeOpen"; text: "Open"; primary: true; onClicked: { const id = root.threadId; root.dismiss(); root.openRequested(id) } }
        }
    }
}
