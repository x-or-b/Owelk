import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

ColumnLayout {
    id: root
    required property var controller
    property url currentSource: ""
    property bool expanded: false
    readonly property var papers: researchStore.paperIndex.documents
    component FilterCombo: ComboBox {
        id: control
        implicitHeight: 32
        leftPadding: 10; rightPadding: 26
        palette.text: "#243b58"
        palette.buttonText: "#243b58"
        palette.highlight: "#d5deea"
        palette.highlightedText: "#182e49"
        background: Rectangle {
            radius: 3
            color: control.down ? "#cbd5e1" : control.hovered ? "#dbe2eb" : "#e5e9ef"
            border.color: control.activeFocus ? "#496684" : "#9caabb"
        }
        contentItem: Text {
            text: control.displayText; textFormat: Text.PlainText
            font: control.font; color: "#243b58"
            verticalAlignment: Text.AlignVCenter; elide: Text.ElideRight
        }
        indicator: Text {
            x: control.width - width - 9; anchors.verticalCenter: parent.verticalCenter
            text: "▾"; color: "#243b58"
        }
        delegate: ItemDelegate {
            id: option
            required property int index
            objectName: control.objectName + "Option" + index
            width: control.width
            highlighted: control.highlightedIndex === index
            background: Rectangle {
                color: option.hovered || option.highlighted ? "#d5deea" : option.index === control.currentIndex ? "#e6ecf3" : "#fafbfd"
            }
            contentItem: Text {
                text: control.textAt(option.index); textFormat: Text.PlainText
                color: "#203650"; font.family: control.font.family; font.pixelSize: control.font.pixelSize
                font.bold: option.index === control.currentIndex
                verticalAlignment: Text.AlignVCenter; elide: Text.ElideMiddle
            }
            ToolTip.visible: hovered && control.textRole === "title" && index > 0
            ToolTip.text: control.textRole === "title" && index > 0 ? root.papers[index - 1].source.toString() : ""
        }
        popup: Popup {
            y: control.height + 3; width: control.width; padding: 1
            implicitHeight: Math.min(contentItem.implicitHeight + 2, 280)
            background: Rectangle { color: "#fafbfd"; border.color: "#9caabb"; radius: 3 }
            contentItem: ListView {
                clip: true; implicitHeight: contentHeight
                model: control.popup.visible ? control.delegateModel : null
                currentIndex: control.highlightedIndex
                ScrollBar.vertical: ScrollBar {}
            }
        }
    }
    RowLayout {
        Layout.fillWidth: true
        ToolButton { text: "← Back"; visible: root.controller.history.length > 0; onClicked: root.controller.back() }
        ToolButton {
            id: filtersButton
            objectName: "searchFiltersButton"
            text: "Filters"; checkable: true; checked: root.expanded; onClicked: root.expanded = checked
            contentItem: Text { text: filtersButton.text; color: "#243b58"; font: filtersButton.font; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
            background: Rectangle {
                radius: 3; border.color: "#9caabb"
                color: filtersButton.checked ? "#cbd5e1" : filtersButton.hovered ? "#dbe2eb" : "#e5e9ef"
            }
        }
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
        FilterCombo {
            objectName: "searchTargetFilter"
            Layout.preferredWidth: 130
            model: ["Everything", "PDF text", "File names", "Captures"]
            readonly property var values: ["all", "text", "filename", "captures"]
            currentIndex: Math.max(0, values.indexOf(root.controller.targetFilter))
            onActivated: root.controller.targetFilter = values[currentIndex]
        }
        FilterCombo {
            id: paperPicker
            objectName: "searchPaperFilter"
            Layout.fillWidth: true
            textRole: "title"
            model: [{title: "All papers", source: ""}].concat(root.papers)
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
