import QtQuick
import Owelk.Ui

Binding {
    property var surface: null
    target: surface && surface.radius !== undefined ? surface : null
    property: "radius"
    value: Theme.radius
    when: target !== null
}
