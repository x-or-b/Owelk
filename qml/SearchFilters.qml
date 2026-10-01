import "UiTheme.js" as Theme
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

ColumnLayout {
    id: root
    required property var controller
    property url currentSource: ""
    property bool expanded: false
    readonly property var papers: researchStore.paperIndex.documents
    component FilterButton: UiControls.ToolButton {
        id: button
        Layout.preferredHeight: 32
        implicitHeight: 32
        leftPadding: 10; rightPadding: 10
        contentItem: Text {
            text: button.text; color: button.enabled ? Theme.textBody : Theme.textDisabled; font: button.font
            horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter
        }
        background: Rectangle {
            radius: Theme.cornerRadius
            color: !button.enabled ? Theme.controlDisabled : button.checked || button.down ? Theme.accentSurface : button.hovered ? Theme.controlHover : Theme.controlFill
            border.color: button.activeFocus || button.checked ? Theme.accentMuted : Theme.borderControl
        }
    }
    component FilterCombo: UiControls.ComboBox {
        id: control
        implicitHeight: 32
        Layout.preferredHeight: 32
        leftPadding: 10; rightPadding: 26
        palette.text: Theme.textBody
        palette.buttonText: Theme.textBody
        palette.highlight: Theme.selectionFill
        palette.highlightedText: Theme.selectionText
        background: Rectangle {
            radius: Theme.cornerRadius
            color: control.down ? Theme.accentSurface : control.hovered ? Theme.controlHover : Theme.controlFill
            border.color: control.activeFocus ? Theme.accentMuted : Theme.borderControl
        }
        contentItem: Text {
            text: control.displayText; textFormat: Text.PlainText
            font: control.font; color: Theme.textBody
            verticalAlignment: Text.AlignVCenter; elide: Text.ElideRight
        }
        indicator: Text {
            x: control.width - width - 9; anchors.verticalCenter: parent.verticalCenter
            text: "▾"; color: Theme.textBody
        }
        delegate: UiControls.ItemDelegate {
            id: option
            required property int index
            objectName: control.objectName + "Option" + index
            width: control.width
            highlighted: control.highlightedIndex === index
            background: Rectangle {
                color: option.index === control.currentIndex ? Theme.accentSurface : option.hovered || option.highlighted ? Theme.menuHover : Theme.surfacePanel
            }
            contentItem: Text {
                text: control.textAt(option.index); textFormat: Text.PlainText
                color: Theme.textBody; font.family: control.font.family; font.pixelSize: control.font.pixelSize
                font.bold: option.index === control.currentIndex
                verticalAlignment: Text.AlignVCenter; elide: Text.ElideMiddle
            }
            ToolTip.visible: hovered && control.textRole === "title" && index > 0
            ToolTip.text: control.textRole === "title" && index > 0 ? root.papers[index - 1].source.toString() : ""
        }
        popup: UiControls.Popup {
            id: filterPopup
            parent: control
            y: control.height + 3; width: control.width; padding: 1
            implicitHeight: Math.min(filterOptions.contentHeight + 2, 280)
            background: Rectangle { color: Theme.surfacePanel; border.color: Theme.borderControl; radius: Theme.cornerRadius }
            contentItem: ListView {
                id: filterOptions
                clip: true; implicitHeight: filterOptions.contentHeight
                model: control.popup.visible ? control.delegateModel : null
                currentIndex: control.highlightedIndex
                ScrollBar.vertical: ScrollBar {}
            }
        }
    }
    RowLayout {
        Layout.fillWidth: true
        FilterButton { text: "← Back"; visible: root.controller.history.length > 0; onClicked: root.controller.back() }
        FilterButton {
            id: filtersButton
            objectName: "searchFiltersButton"
            text: "Filters"; checkable: true; checked: root.expanded; onClicked: root.expanded = checked
        }
        Label {
            Layout.fillWidth: true
            text: (root.controller.sourceFilter.toString().length ? researchStore.fileName(root.controller.sourceFilter) : "All papers")
                + (root.controller.targetFilter === "all" ? "" : " · " + ({text: "PDF text", filename: "File names", captures: "Captures"})[root.controller.targetFilter])
            textFormat: Text.PlainText; elide: Text.ElideMiddle; color: Theme.textTertiary; font.pixelSize: 11
        }
        FilterButton {
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
        FilterButton {
            objectName: "currentPdfFilter"
            text: "Current PDF"
            enabled: root.currentSource.toString().length > 0
            onClicked: root.controller.sourceFilter = root.currentSource
        }
    }
}
