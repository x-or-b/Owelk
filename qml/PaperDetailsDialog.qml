import "UiTheme.js" as Theme
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Edit the title and bibliographic details shown for a PDF. The PDF file itself is never changed.
UiControls.Dialog {
    id: root
    objectName: "paperDetails"
    parent: Overlay.overlay
    anchors.centerIn: parent
    width: Math.min(520, parent ? parent.width - 32 : 520)
    title: "Paper details"
    modal: true
    property url source: ""
    property var details: ({})
    function begin(url) {
        source = url
        details = researchStore.documentDetails(url)
        titleField.text = details.title || ""
        authorsField.text = details.authors || ""
        yearField.text = details.year || ""
        doiField.text = details.doi || ""
        arxivField.text = details.arxiv || ""
        open()
        titleField.forceActiveFocus()
    }
    function save() {
        if (researchStore.updateDocumentDetails(source, {title: titleField.text, authors: authorsField.text,
                year: yearField.text, doi: doiField.text, arxiv: arxivField.text})) close()
    }
    footer: RowLayout {
        spacing: 8
        Item { Layout.preferredWidth: 4 }
        UiControls.Button {
            objectName: "readDetailsFromPdf"
            text: "Read from PDF"
            ToolTip.visible: hovered; ToolTip.delay: 450
            ToolTip.text: "Discard edits and read the details from the PDF again"
            onClicked: { researchStore.resetDocumentDetails(root.source); root.close() }
        }
        Item { Layout.fillWidth: true }
        UiControls.Button { text: "Cancel"; onClicked: root.close() }
        UiControls.Button { objectName: "saveDetails"; text: "Save"; highlighted: true; onClicked: root.save() }
        Item { Layout.preferredWidth: 4 }
    }
    GridLayout {
        width: parent.width
        columns: 2
        columnSpacing: 10
        rowSpacing: 8
        Label { text: "File"; color: Theme.textTertiary }
        Label {
            Layout.fillWidth: true; text: root.details.fileName || ""; elide: Text.ElideMiddle
            textFormat: Text.PlainText; color: Theme.textTertiary
        }
        Label { text: "Title"; color: Theme.textBody }
        UiControls.TextField {
            id: titleField; objectName: "detailsTitle"; Layout.fillWidth: true
            placeholderText: "Shown instead of the file name"; maximumLength: 300; onAccepted: root.save()
        }
        Label { text: "Authors"; color: Theme.textBody }
        UiControls.TextField { id: authorsField; objectName: "detailsAuthors"; Layout.fillWidth: true; maximumLength: 1000; onAccepted: root.save() }
        Label { text: "Year"; color: Theme.textBody }
        UiControls.TextField {
            id: yearField; objectName: "detailsYear"; Layout.preferredWidth: 80; maximumLength: 4
            validator: RegularExpressionValidator { regularExpression: /\d{0,4}/ }
            onAccepted: root.save()
        }
        Label { text: "DOI"; color: Theme.textBody }
        UiControls.TextField { id: doiField; Layout.fillWidth: true; maximumLength: 200; onAccepted: root.save() }
        Label { text: "arXiv ID"; color: Theme.textBody }
        UiControls.TextField { id: arxivField; Layout.fillWidth: true; maximumLength: 40; onAccepted: root.save() }
    }
}
