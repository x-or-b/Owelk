import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "PaletteMatch.js" as Match
import "UiTheme.js" as Theme

UiControls.ItemDelegate {
    id: root
    required property var modelData
    property string queryText: ""
    readonly property bool heading: queryText.trim().length > 0 && (modelData.kind === "paperGroup" || modelData.kind === "paper")
    height: modelData.snippet ? 76 : 44
    background: Rectangle {
        color: root.heading ? (root.highlighted || root.hovered ? "#686868" : "#767676") : root.highlighted ? "#e9e9e9" : root.hovered ? "#f2f2f2" : "transparent"
        Rectangle { visible: root.highlighted; y: Theme.cornerRadius; width: 3; height: parent.height - 2 * y; radius: 1.5; color: "#829ab4" }
    }
    contentItem: ColumnLayout {
        spacing: 3
        RowLayout {
            Layout.fillWidth: true
            Label {
                objectName: "resultTitle"
                Layout.fillWidth: true
                text: Match.highlight(root.modelData.title, root.queryText, root.heading ? "#c5dcf5" : "#426b9a")
                textFormat: Text.StyledText
                color: root.heading ? "#ffffff" : root.modelData.kind === "text" ? "#243e60" : "#333333"
                font.bold: root.modelData.kind === "paperGroup"
                elide: Text.ElideMiddle
            }
            Label {
                text: root.modelData.kind === "paperGroup" ? root.modelData.total + " matching pages"
                    : root.modelData.kind === "text" ? "p. " + (Number(root.modelData.page) + 1)
                    : ["moreInPaper", "nextResults"].indexOf(root.modelData.kind) >= 0 ? "" : root.modelData.kind
                color: root.heading ? "#e5e5e5" : "#777777"; font.pixelSize: 11
            }
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
