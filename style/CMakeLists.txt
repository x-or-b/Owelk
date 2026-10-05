# The Owelk Qt Quick Controls style: every stock control (and the shared Icon/IconButton)
# follows the Theme tokens; anything not restyled here falls back to Basic.
qt_add_library(owelk_style STATIC)
qt_add_qml_module(owelk_style
    URI OwelkStyle VERSION 1.0
    IMPORTS QtQuick.Controls.Basic
    QML_FILES Button.qml ToolButton.qml TextField.qml TextArea.qml Label.qml ToolTip.qml ScrollBar.qml
        Menu.qml MenuItem.qml MenuSeparator.qml ItemDelegate.qml TabBar.qml TabButton.qml
        ComboBox.qml CheckBox.qml Switch.qml Slider.qml Popup.qml Dialog.qml DialogButtonBox.qml
        Chip.qml ListGroup.qml Icon.qml IconButton.qml Icons.js
)
target_link_libraries(owelk_style PRIVATE Qt6::Quick Qt6::QuickControls2)
