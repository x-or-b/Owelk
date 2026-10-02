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
    readonly property string byline: modelData.kind === "paper" ? [modelData.authors, modelData.year].filter(function(s) { return s && String(s).length }).join("  ·  ") : ""
    height: (modelData.snippet ? 76 : 44) + (byline.length ? 14 : 0)
    background: Rectangle {
        color: root.heading ? (root.highlighted || root.hovered ? Theme.searchHeadingHover : Theme.searchHeading) : root.highlighted ? Theme.surfaceSelected : root.hovered ? Theme.surfaceHover : "transparent"
    }
    contentItem: ColumnLayout {
        spacing: 3
        RowLayout {
            Layout.fillWidth: true
            Label {
                objectName: "resultTitle"
                Layout.fillWidth: true
                text: Match.highlight(root.modelData.title, root.queryText, root.heading ? Theme.accentOnDark : Theme.accent)
                textFormat: Text.StyledText
                color: root.heading ? Theme.onDark : root.modelData.kind === "text" ? Theme.accentText : Theme.textBody
                font.bold: root.modelData.kind === "paperGroup"
                elide: root.modelData.kind === "paper" ? Text.ElideRight : Text.ElideMiddle
            }
            Label {
                text: root.modelData.kind === "paperGroup" ? root.modelData.total + " matching pages"
                    : root.modelData.kind === "text" ? "p. " + (Number(root.modelData.page) + 1)
                    : ["moreInPaper", "nextResults"].indexOf(root.modelData.kind) >= 0 ? ""
                    : root.modelData.kind === "paper" ? "" : root.modelData.kind
                color: root.heading ? Theme.onDarkMuted : Theme.textMuted; font.pixelSize: 11
            }
        }
        // Papers read like the Library: title, then authors · year.
        Label {
            objectName: "resultByline"
            Layout.fillWidth: true
            visible: root.byline.length > 0
            text: root.byline
            textFormat: Text.PlainText
            elide: Text.ElideRight
            color: root.heading ? Theme.onDarkMuted : Theme.textTertiary
            font.pixelSize: 11
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
            color: Theme.textTertiary
            font.pixelSize: 12
        }
    }
}
