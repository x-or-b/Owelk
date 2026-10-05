import QtQuick
import QtQuick.Controls.impl
import QtQuick.Templates as T
import Owelk.Ui

// A rounded popover menu, as wide as its longest row (never cuts a label).
T.Menu {
    id: control
    implicitWidth: {
        let widest = 0
        for (let i = 0; i < count; ++i) {
            const item = itemAt(i)
            if (item && item.visible) widest = Math.max(widest, item.implicitWidth)
        }
        return Math.min(420, Math.max(implicitBackgroundWidth + leftInset + rightInset, widest + leftPadding + rightPadding))
    }
    implicitHeight: Math.max(implicitBackgroundHeight + topInset + bottomInset, implicitContentHeight + topPadding + bottomPadding)
    margins: 6
    overlap: 4
    padding: 5
    delegate: MenuItem {}
    contentItem: ListView {
        implicitHeight: contentHeight
        model: control.contentModel
        interactive: Window.window ? contentHeight + control.topPadding + control.bottomPadding > control.height : false
        clip: true
        currentIndex: control.currentIndex
        ScrollIndicator.vertical: ScrollIndicator {}
    }
    background: Rectangle {
        implicitWidth: 180
        implicitHeight: 32
        radius: Theme.radiusLarge
        color: Theme.raised
        border.color: Theme.border
    }
    T.Overlay.modal: Rectangle { color: "transparent" }
    T.Overlay.modeless: Rectangle { color: "transparent" }
}
