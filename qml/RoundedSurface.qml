import QtQuick
import "UiTheme.js" as Theme

Binding {
    property var surface: null
    target: surface && surface.radius !== undefined ? surface : null
    property: "radius"
    value: Theme.cornerRadius
    when: target !== null
}
