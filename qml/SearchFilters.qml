import Owelk.Ui
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

ColumnLayout {
    id: root
    required property var controller
    property url currentSource: ""
    // One row: where to search, plus This PDF in the reader. Library conditions are typed into the
    // query (tag:, collection:, state:, year:, workspace:) instead of filling the box with menus.
    Flow {
        Layout.fillWidth: true; Layout.minimumWidth: 0
        spacing: 4
        IconButton { icon.name: "back"; description: "Back to the previous search"; visible: root.controller.history.length > 0; onClicked: root.controller.back() }
        Repeater {
            model: [{value: "all", name: "All"}, {value: "text", name: "PDF text"}, {value: "filename", name: "Papers"},
                    {value: "captures", name: "Captures"}, {value: "ai", name: "AI"}]
            delegate: Chip {
                required property var modelData
                objectName: "searchTarget-" + modelData.value
                text: modelData.name
                checkable: true
                checked: root.controller.targetFilter === modelData.value
                onClicked: root.controller.targetFilter = modelData.value
            }
        }
        Chip {
            objectName: "currentPdfFilter"
            visible: root.currentSource.toString().length > 0
            text: "This PDF"
            checkable: true
            checked: root.currentSource.toString().length > 0 && researchStore.sameSource(root.controller.sourceFilter, root.currentSource)
            onClicked: root.controller.sourceFilter = checked ? root.currentSource : ""
        }
    }
    // What narrows the results now: a paper opened from a result, and typed library conditions.
    Label {
        objectName: "searchFilterSummary"
        Layout.fillWidth: true; Layout.minimumWidth: 0
        visible: text.length > 0
        text: [root.controller.sourceFilter.toString().length && !researchStore.sameSource(root.controller.sourceFilter, root.currentSource)
                   ? (researchStore.documentsRevision, researchStore.displayName(root.controller.sourceFilter)) : ""]
              .concat(root.controller.tokenLabels).filter(function(s) { return s.length }).join("  ·  ")
        textFormat: Text.PlainText; elide: Text.ElideMiddle; color: Theme.textTertiary; font.pixelSize: Theme.fontCaption
    }
}
