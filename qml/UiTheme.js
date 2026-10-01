.pragma library

// UI surfaces only. PDF page/selection geometry must remain unchanged.
var cornerRadius = 5
// Accent family from Cmd+K. Keep neutral surfaces gray; reserve red for destructive/error states.
var accent = "#426b9a"
var accentMuted = "#829ab4"
var accentSurface = "#d9dfe6"
var accentOnDark = "#c5dcf5"
var accentText = "#243e60"
var captureBorder = accent
// Milliseconds from peak emphasis to fully invisible; adjust this to tune capture navigation.
var captureFadeDuration = 300

// Text, darkest to lightest.
var textStrong = "#171717"      // hovered glyphs
var text = "#242424"            // primary text, window text
var textBody = "#333333"        // labels, control text
var textQuote = "#444444"       // read-only excerpts, capture text
var textSecondary = "#555555"   // secondary detail
var textTertiary = "#666666"    // meta lines, counts
var textMuted = "#777777"       // hints, empty states, placeholders
var textDisabled = "#777777"
var danger = "#b42323"          // errors and destructive actions only
var onDark = "#ffffff"
var onDarkMuted = "#e5e5e5"
var icon = "#555555"
var iconStrong = "#333333"

// Surfaces, lightest to darkest.
var surface = "#ffffff"         // base, popups, active tab
var surfacePanel = "#fafafa"    // panels, menus, window palette
var surfaceSidebar = "#f7f7f7"
var surfaceAlt = "#f5f5f5"      // toolbars, segments, alternate rows
var surfaceHover = "#f2f2f2"    // list row hover
var surfaceMuted = "#f0f0f0"    // list cards
var surfaceChrome = "#eeeeee"   // window chrome, buttons, highlighted rows
var surfaceSelected = "#e9e9e9" // selected row, inactive tab
var readerBackground = "#e8e8e8"

// Controls.
var controlFill = "#e8e8e8"
var controlHover = "#dedede"    // hovered/selected control or row
var controlDisabled = "#eeeeee"
var menuHover = "#e2e2e2"
var iconHover = "#e5e5e5"
var segmentChecked = "#d8d8d8"
var tabHover = "#dddddd"
var tabPressed = "#cccccc"
var tabUnderline = "#d5d5d5"
var tabUnderlineActive = "#777777"
var selectionFill = "#d5deea"
var selectionText = "#182e49"
var searchHeading = "#767676"
var searchHeadingHover = "#686868"

// Borders and dividers.
var border = "#dddddd"          // cards, dividers
var borderSegment = "#cccccc"
var borderPane = "#d6d6d6"
var borderPaneActive = "#888888"
var borderReadOnly = "#d2d2d2"
var borderPopup = "#bcbcbc"
var borderControl = "#b5b5b5"
var borderSelected = "#777777"
var focusRing = "#999999"
var overlayBorder = "#555555"   // drop and capture rectangles
var splitter = "#e3e3e3"
var splitterHover = "#bbbbbb"
var edgeHandle = "#eeeeee"
var edgeHandleHover = "#bcbcbc"

// Scrollbars.
var scrollTrack = "#eeeeee"
var scrollHandle = "#b5b5b5"
var scrollHandleHover = "#999999"
var scrollHandlePressed = "#777777"

// Window palette extras.
var highlight = "#555555"
var shadeMid = "#c5c5c5"
var shadeDark = "#888888"
var shadow = "#555555"

// Annotation inks; order is the picker order.
var annotationInks = [
    { name: "Blue", value: "#426b9a" },
    { name: "Yellow", value: "#e0b83f" },
    { name: "Green", value: "#54a878" },
    { name: "Pink", value: "#d87797" },
    { name: "Purple", value: "#9274c3" }
]
var defaultInk = annotationInks[0].value
