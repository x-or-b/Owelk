import QtQuick
import QtQuick.Controls.Basic as Controls

QtObject {
    // Keep Basic's sizing, palette, focus, hover and disabled behavior. Only shape changes.
    component Button: Controls.Button { id: control; RoundedSurface { surface: control.background } }
    component ToolButton: Controls.ToolButton { id: control; RoundedSurface { surface: control.background } }
    component TabButton: Controls.TabButton {
        id: control
        contentItem: Text {
            text: control.text; font: control.font
            color: control.enabled ? "#242424" : "#777777"
            horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter
            elide: Text.ElideRight
        }
        RoundedSurface { surface: control.background }
    }
    component TextField: Controls.TextField { id: control; RoundedSurface { surface: control.background } }
    component TextArea: Controls.TextArea { id: control; RoundedSurface { surface: control.background } }
    component ItemDelegate: Controls.ItemDelegate { id: control; RoundedSurface { surface: control.background } }
    component MenuItem: Controls.MenuItem { id: control; RoundedSurface { surface: control.background } }
    component Menu: Controls.Menu { id: control; RoundedSurface { surface: control.background } }
    component Popup: Controls.Popup { id: control; RoundedSurface { surface: control.background } }
    component ComboBox: Controls.ComboBox {
        id: control
        RoundedSurface { surface: control.background }
        RoundedSurface { surface: control.popup ? control.popup.background : null }
    }
    component Dialog: Controls.Dialog {
        id: control
        RoundedSurface { surface: control.background }
        RoundedSurface { surface: control.header ? control.header.background : null }
        footer: Controls.DialogButtonBox {
            id: buttons
            visible: count > 0
            RoundedSurface { surface: buttons.background }
            delegate: Controls.Button {
                id: button
                width: buttons.count === 1 ? buttons.availableWidth / 2 : implicitWidth
                RoundedSurface { surface: button.background }
            }
        }
    }
}
