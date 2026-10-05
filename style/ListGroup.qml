import QtQuick
import Owelk.Ui

// Rows grouped on a rounded card (macOS settings and lists). Put rows in `content`;
// give rows `separator: index < count - 1`.
Rectangle {
    default property alias content: column.data
    property alias spacing: column.spacing
    implicitHeight: column.implicitHeight + 8
    radius: Theme.radiusLarge
    color: Theme.content
    border.color: Theme.separator
    Column {
        id: column
        x: 4; y: 4
        width: parent.width - 8
        spacing: 1
    }
}
