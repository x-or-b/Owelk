.pragma library

// How reasoning efforts are named in menus (the provider's level ids → words).
function effortName(value) {
    const names = {minimal: "Minimal", low: "Low", medium: "Medium", high: "High", xhigh: "Extra high", max: "Max", ultra: "Ultra"}
    return names[value] || (value ? value.charAt(0).toUpperCase() + value.slice(1) : "")
}
