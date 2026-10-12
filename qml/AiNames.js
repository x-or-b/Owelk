.pragma library

// How reasoning efforts are named in menus (the provider's level ids → words).
function effortName(value) {
    const names = {minimal: qsTr("Minimal"), low: qsTr("Low"), medium: qsTr("Medium"), high: qsTr("High"), xhigh: qsTr("Extra high"), max: qsTr("Max"), ultra: qsTr("Ultra")}
    return names[value] || (value ? value.charAt(0).toUpperCase() + value.slice(1) : "")
}
