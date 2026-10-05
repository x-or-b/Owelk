import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Owelk.Ui

// One settings row: the name on the left, its control on the right; a hairline above
// every row but the first in its group.
Item {
    id: root
    property string label: ""
    property string detail: ""
    default property alias control: slot.data
    // A wide control (a text field) takes the space next to the name.
    property alias wide: slot.wide
    width: parent ? parent.width : 0
    implicitHeight: Math.max(Theme.controlHeight + 14, row.implicitHeight + 12)
    Rectangle {
        visible: root.Positioner.index > 0
        x: 10; width: parent.width - 20; height: 1
        color: Theme.separator
    }
    RowLayout {
        id: row
        anchors.fill: parent
        anchors.leftMargin: 12; anchors.rightMargin: 10
        spacing: 12
        ColumnLayout {
            visible: root.label.length > 0
            Layout.fillWidth: slot.children.length === 0 || !slot.wide
            Layout.preferredWidth: slot.wide ? Math.min(200, implicitWidth) : -1
            spacing: 1
            Label { Layout.fillWidth: true; text: root.label; elide: Text.ElideRight; color: Theme.text }
            Label {
                visible: root.detail.length > 0
                Layout.fillWidth: true
                text: root.detail
                wrapMode: Text.Wrap
                font.pixelSize: Theme.fontCaption
                color: Theme.textTertiary
            }
        }
        // Controls sit on the right; a `wide` control (a field) takes the remaining width.
        RowLayout {
            id: slot
            property bool wide: false
            Layout.fillWidth: wide || root.label.length === 0
            Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
            spacing: 6
        }
    }
}
