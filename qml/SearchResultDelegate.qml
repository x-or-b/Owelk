import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "PaletteMatch.js" as Match
import Owelk.Ui

ItemDelegate {
    id: root
    required property var modelData
    property string queryText: ""
    readonly property bool heading: queryText.trim().length > 0 && (modelData.kind === "paperGroup" || modelData.kind === "paper")
    readonly property string byline: modelData.kind === "paper" ? [modelData.authors, modelData.year].filter(function(s) { return s && String(s).length }).join("  ·  ") : ""
    // A section heading ("Similar meaning") is a label, not a result.
    readonly property bool section: modelData.kind === "section"
    enabled: !section
    // Rows follow the shared list look (hover, selection); a paper that groups its matching pages
    // reads as a bold heading rather than a dark bar.
    height: section ? Theme.rowHeight : modelData.kind === "complete" ? Theme.rowHeight + 4 : (modelData.snippet ? Theme.rowHeightTall + 30 : Theme.rowHeightTall) + (byline.length ? 14 : 0)
    contentItem: ColumnLayout {
        spacing: 3
        RowLayout {
            Layout.fillWidth: true
            Label {
                objectName: "resultTitle"
                Layout.fillWidth: true
                text: Match.highlight(root.modelData.title, root.queryText, Theme.accent)
                textFormat: Text.StyledText
                color: root.section ? Theme.textTertiary : Theme.text
                font.weight: root.heading || root.section || root.modelData.kind === "paperGroup" ? Font.DemiBold : Font.Normal
                font.pixelSize: root.section ? Theme.fontCaption : Theme.fontBody
                elide: root.modelData.kind === "paper" ? Text.ElideRight : Text.ElideMiddle
            }
            Label {
                text: root.modelData.kind === "paperGroup" ? root.modelData.total + " matching pages"
                    : root.modelData.kind === "text" ? "p. " + (Number(root.modelData.page) + 1) + (root.modelData.ocr ? " · OCR" : "")
                    : ["moreInPaper", "nextResults", "section"].indexOf(root.modelData.kind) >= 0 ? ""
                    : root.modelData.kind === "paper" ? ""
                    : root.modelData.kind === "complete" ? root.modelData.key + (root.modelData.count !== undefined ? "  ·  " + root.modelData.count + " papers" : "")
                    : root.modelData.kind
                color: Theme.textTertiary; font.pixelSize: Theme.fontCaption
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
            color: Theme.textTertiary
            font.pixelSize: Theme.fontCaption
        }
        Label {
            objectName: "resultSnippet"
            Layout.fillWidth: true
            visible: !!root.modelData.snippet
            text: Match.highlight(root.modelData.snippet || "", root.queryText, Theme.accent)
            textFormat: Text.StyledText
            wrapMode: Text.Wrap
            maximumLineCount: 2
            elide: Text.ElideRight
            color: Theme.textSecondary
            font.pixelSize: Theme.fontSmall
        }
    }
}
