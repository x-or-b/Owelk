import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

ColumnLayout {
    id: root
    required property var controller
    property url currentSource: ""
    property bool expanded: false
    readonly property var papers: researchStore.paperIndex.documents
    RowLayout {
        Layout.fillWidth: true
        ToolButton { text: "← Back"; visible: root.controller.history.length > 0; onClicked: root.controller.back() }
        ToolButton { text: "Filters"; checkable: true; checked: root.expanded; onClicked: root.expanded = checked }
        Label {
            Layout.fillWidth: true
            text: (root.controller.sourceFilter.toString().length ? researchStore.fileName(root.controller.sourceFilter) : "All papers")
                + (root.controller.targetFilter === "all" ? "" : " · " + ({text: "PDF text", filename: "File names", captures: "Captures"})[root.controller.targetFilter])
            textFormat: Text.PlainText; elide: Text.ElideMiddle; color: "#666666"; font.pixelSize: 11
        }
        ToolButton {
            text: "Clear filters"
            visible: root.controller.sourceFilter.toString().length > 0 || root.controller.targetFilter !== "all"
            onClicked: root.controller.resetFilters()
        }
    }
    RowLayout {
        visible: root.expanded
        Layout.fillWidth: true
        ComboBox {
            objectName: "searchTargetFilter"
            Layout.preferredWidth: 130
            model: ["Everything", "PDF text", "File names", "Captures"]
            readonly property var values: ["all", "text", "filename", "captures"]
            currentIndex: Math.max(0, values.indexOf(root.controller.targetFilter))
            onActivated: root.controller.targetFilter = values[currentIndex]
        }
        ComboBox {
            id: paperPicker
            objectName: "searchPaperFilter"
            Layout.fillWidth: true
            textRole: "title"
            model: [{title: "All papers", source: ""}].concat(root.papers)
            contentItem: Text {
                text: paperPicker.displayText; textFormat: Text.PlainText
                font: paperPicker.font; color: "#333333"
                verticalAlignment: Text.AlignVCenter; elide: Text.ElideRight
            }
            delegate: ItemDelegate {
                required property var modelData
                required property int index
                width: paperPicker.width
                highlighted: paperPicker.highlightedIndex === index
                contentItem: Label { text: modelData.title; textFormat: Text.PlainText; elide: Text.ElideMiddle }
                ToolTip.visible: hovered
                ToolTip.text: modelData.source.toString()
            }
            currentIndex: {
                if (!root.controller.sourceFilter.toString().length) return 0
                for (let i = 0; i < root.papers.length; ++i)
                    if (researchStore.sameSource(root.papers[i].source, root.controller.sourceFilter)) return i + 1
                return -1
            }
            onActivated: root.controller.sourceFilter = currentIndex > 0 ? root.papers[currentIndex - 1].source : ""
            ToolTip.visible: hovered && currentIndex > 0
            ToolTip.text: currentIndex > 0 ? root.papers[currentIndex - 1].source.toString() : ""
        }
        ToolButton {
            text: "Current PDF"
            enabled: root.currentSource.toString().length > 0
            onClicked: root.controller.sourceFilter = root.currentSource
        }
    }
}
