import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "PaletteMatch.js" as Match

ItemDelegate {
    id: root
    required property var modelData
    property string queryText: ""
    height: modelData.snippet ? 76 : 44
    background: Rectangle { color: root.highlighted ? "#e9e9e9" : root.hovered ? "#f2f2f2" : "transparent" }
    contentItem: ColumnLayout {
        spacing: 3
        RowLayout {
            Layout.fillWidth: true
            Label {
                objectName: "resultTitle"
                Layout.fillWidth: true
                text: Match.highlight(root.modelData.title, root.queryText)
                textFormat: Text.StyledText
                color: "#333333"
                elide: Text.ElideMiddle
            }
            Label { text: root.modelData.kind === "text" ? "p. " + (Number(root.modelData.page) + 1) : root.modelData.kind; color: "#777777"; font.pixelSize: 11 }
        }
        Label {
            objectName: "resultSnippet"
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
