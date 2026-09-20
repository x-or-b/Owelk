import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "PaletteMatch.js" as Match

ItemDelegate {
    id: root
    required property var modelData
    property string queryText: ""
    height: modelData.snippet ? 76 : 44
    contentItem: ColumnLayout {
        spacing: 3
        RowLayout {
            Layout.fillWidth: true
            Label { Layout.fillWidth: true; text: root.modelData.title; textFormat: Text.PlainText; elide: Text.ElideMiddle }
            Label { text: root.modelData.kind === "text" ? "p. " + (Number(root.modelData.page) + 1) : root.modelData.kind; color: "#777777"; font.pixelSize: 11 }
        }
        Label {
            Layout.fillWidth: true
            visible: !!root.modelData.snippet
            text: Match.highlight(root.modelData.snippet || "", root.queryText)
            textFormat: Text.StyledText
            wrapMode: Text.Wrap
            maximumLineCount: 2
            elide: Text.ElideRight
            color: "#666666"
            font.pixelSize: 12
        }
    }
}
