import QtQuick
import QtQuick.Templates as T
import Owelk.Ui

// Overlay scroll bar: a thin rounded handle that shows while scrolling or hovered.
T.ScrollBar {
    id: control
    implicitWidth: Math.max(implicitBackgroundWidth + leftInset + rightInset, implicitContentWidth + leftPadding + rightPadding)
    implicitHeight: Math.max(implicitBackgroundHeight + topInset + bottomInset, implicitContentHeight + topPadding + bottomPadding)
    padding: 2
    visible: control.policy !== T.ScrollBar.AlwaysOff
    minimumSize: orientation === Qt.Horizontal ? height / width : width / height
    contentItem: Rectangle {
        implicitWidth: control.interactive ? 8 : 4
        implicitHeight: control.interactive ? 8 : 4
        radius: Math.min(width, height) / 2
        color: control.pressed ? Theme.scrollHandlePressed : control.hovered ? Theme.scrollHandleHover : Theme.scrollHandle
        opacity: 0
        states: State {
            name: "active"
            when: control.policy === T.ScrollBar.AlwaysOn || (control.size < 1.0 && (control.active || control.hovered))
            PropertyChanges { control.contentItem.opacity: 1 }
        }
        transitions: Transition {
            from: "active"
            SequentialAnimation {
                PauseAnimation { duration: 600 }
                NumberAnimation { target: control.contentItem; property: "opacity"; duration: 200; to: 0 }
            }
        }
    }
}
