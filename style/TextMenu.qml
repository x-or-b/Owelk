import QtQuick

// Right-click menu of every TextField and TextArea, made on the first right-click. Each action is
// enabled only when it can act (nothing selected: no Cut or Copy; read-only: no Paste).
Menu {
    id: menu
    property Item target
    property bool keptSelection: false
    readonly property bool editable: !target.readOnly && target.enabled
    readonly property bool selected: target.selectionEnd > target.selectionStart
    // Passwords are never copied out.
    readonly property bool hidden: target.echoMode !== undefined && target.echoMode !== TextInput.Normal
    function show(x, y) {
        // The menu takes focus; the selection stays visible and usable meanwhile.
        keptSelection = target.persistentSelection
        target.persistentSelection = true
        popup(x, y)
    }
    onClosed: {
        target.persistentSelection = keptSelection
        target.forceActiveFocus()
    }
    MenuItem { objectName: "textMenuUndo"; text: "Undo"; enabled: menu.editable && menu.target.canUndo; onTriggered: menu.target.undo() }
    MenuItem { objectName: "textMenuRedo"; text: "Redo"; enabled: menu.editable && menu.target.canRedo; onTriggered: menu.target.redo() }
    MenuSeparator {}
    MenuItem { objectName: "textMenuCut"; text: "Cut"; enabled: menu.editable && menu.selected && !menu.hidden; onTriggered: menu.target.cut() }
    MenuItem { objectName: "textMenuCopy"; text: "Copy"; enabled: menu.selected && !menu.hidden; onTriggered: menu.target.copy() }
    MenuItem { objectName: "textMenuPaste"; text: "Paste"; enabled: menu.editable && menu.target.canPaste; onTriggered: menu.target.paste() }
    MenuItem {
        objectName: "textMenuDelete"; text: "Delete"
        enabled: menu.editable && menu.selected
        onTriggered: menu.target.remove(menu.target.selectionStart, menu.target.selectionEnd)
    }
    MenuSeparator {}
    MenuItem {
        objectName: "textMenuSelectAll"; text: "Select All"
        enabled: menu.target.length > 0 && menu.target.selectedText.length < menu.target.length
        onTriggered: menu.target.selectAll()
    }
}
