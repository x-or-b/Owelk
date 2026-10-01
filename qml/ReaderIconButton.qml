import QtQuick
import QtQuick.Controls
import "UiTheme.js" as Theme

UiControls.ToolButton {
    id: root
    property string kind: ""
    property string description: ""
    property color swatch: "transparent"
    // Stroke color; Theme.danger for destructive actions.
    property color tint: Theme.iconStrong
    implicitWidth: 28
    implicitHeight: 26
    hoverEnabled: true
    Accessible.name: description
    ToolTip.visible: hovered
    ToolTip.delay: 450
    ToolTip.text: description
    background: Rectangle {
        color: root.checked ? Theme.accentSurface : root.hovered ? Theme.iconHover : "transparent"
        border.color: root.visualFocus || root.checked ? Theme.accent : "transparent"
    }
    contentItem: Item {
        Canvas {
            id: icon
            width: 18
            height: 18
            anchors.centerIn: parent
            opacity: root.enabled ? 1 : .4
            onPaint: {
                const c = getContext("2d");
                c.reset();
                c.strokeStyle = root.tint;
                c.lineWidth = 1.4;
                c.lineJoin = "round";
                c.lineCap = "round";
                c.beginPath();
                switch (root.kind) {
                case "highlight":
                    c.moveTo(4, 12);
                    c.lineTo(11, 3);
                    c.lineTo(16, 7);
                    c.lineTo(9, 15);
                    c.closePath();
                    c.moveTo(4, 12);
                    c.lineTo(2, 16);
                    c.lineTo(7, 15);
                    break;
                case "comment":
                    c.moveTo(2, 3);
                    c.lineTo(16, 3);
                    c.lineTo(16, 13);
                    c.lineTo(8, 13);
                    c.lineTo(4, 16);
                    c.lineTo(4, 13);
                    c.lineTo(2, 13);
                    c.closePath();
                    c.moveTo(5, 7);
                    c.lineTo(13, 7);
                    c.moveTo(5, 10);
                    c.lineTo(10, 10);
                    break;
                case "text":
                    c.rect(2, 2, 14, 14);
                    c.moveTo(5, 5);
                    c.lineTo(13, 5);
                    c.moveTo(9, 5);
                    c.lineTo(9, 13);
                    c.moveTo(7, 13);
                    c.lineTo(11, 13);
                    break;
                case "image":
                    c.rect(2, 2, 14, 14);
                    c.moveTo(3, 13);
                    c.lineTo(7, 9);
                    c.lineTo(10, 12);
                    c.lineTo(13, 7);
                    c.lineTo(16, 10);
                    c.moveTo(7, 6);
                    c.arc(6, 6, 1, 0, Math.PI * 2);
                    break;
                case "draw":
                    c.moveTo(2, 14);
                    c.bezierCurveTo(9, 0, 1, 3, 8, 11);
                    c.bezierCurveTo(15, 18, 11, 2, 16, 4);
                    break;
                case "print":
                    c.rect(4, 1, 10, 5);
                    c.rect(2, 6, 14, 8);
                    c.rect(5, 11, 8, 6);
                    break;
                case "excerpt":
                    c.rect(3, 2, 12, 14);
                    c.moveTo(6, 5);
                    c.lineTo(12, 5);
                    c.moveTo(6, 8);
                    c.lineTo(12, 8);
                    c.moveTo(6, 11);
                    c.lineTo(10, 11);
                    break;
                case "capture":
                    c.moveTo(6, 2);
                    c.lineTo(2, 2);
                    c.lineTo(2, 6);
                    c.moveTo(12, 2);
                    c.lineTo(16, 2);
                    c.lineTo(16, 6);
                    c.moveTo(2, 12);
                    c.lineTo(2, 16);
                    c.lineTo(6, 16);
                    c.moveTo(12, 16);
                    c.lineTo(16, 16);
                    c.lineTo(16, 12);
                    break;
                case "restore":
                    c.moveTo(4, 5);
                    c.lineTo(4, 9);
                    c.lineTo(8, 9);
                    c.moveTo(4.6, 8.4);
                    c.arc(10, 10, 6, Math.PI * 1.15, Math.PI * 0.85, false);
                    break;
                case "trash":
                    c.moveTo(3, 5);
                    c.lineTo(15, 5);
                    c.moveTo(7, 5);
                    c.lineTo(7, 3);
                    c.lineTo(11, 3);
                    c.lineTo(11, 5);
                    c.moveTo(5, 5);
                    c.lineTo(6, 16);
                    c.lineTo(12, 16);
                    c.lineTo(13, 5);
                    c.moveTo(8, 8);
                    c.lineTo(8, 13);
                    c.moveTo(10, 8);
                    c.lineTo(10, 13);
                    break;
                case "back":
                    c.moveTo(11, 4);
                    c.lineTo(6, 9);
                    c.lineTo(11, 14);
                    break;
                case "forward":
                    c.moveTo(7, 4);
                    c.lineTo(12, 9);
                    c.lineTo(7, 14);
                    break;
                case "reload":
                    c.moveTo(14.5, 5.5);
                    c.arc(9, 9, 5.5, -Math.PI * 0.2, Math.PI * 1.55, false);
                    c.moveTo(14.5, 2.5);
                    c.lineTo(14.5, 6);
                    c.lineTo(11, 6);
                    break;
                case "star":
                    for (let i = 0; i < 10; ++i) {
                        const r = i % 2 ? 3 : 7, a = -Math.PI / 2 + i * Math.PI / 5;
                        if (i) c.lineTo(9 + r * Math.cos(a), 9.5 + r * Math.sin(a));
                        else c.moveTo(9 + r * Math.cos(a), 9.5 + r * Math.sin(a));
                    }
                    c.closePath();
                    break;
                case "link":
                    c.moveTo(8, 10);
                    c.lineTo(10, 8);
                    c.moveTo(7, 7);
                    c.lineTo(5, 9);
                    c.arc(6.5, 11.5, 2.5, Math.PI * 1.25, Math.PI * 0.25, true);
                    c.moveTo(11, 11);
                    c.lineTo(13, 9);
                    c.arc(11.5, 6.5, 2.5, Math.PI * 0.25, Math.PI * 1.25, true);
                    break;
                case "ai":
                    c.moveTo(8, 2);
                    c.quadraticCurveTo(8.5, 7.5, 14, 8);
                    c.quadraticCurveTo(8.5, 8.5, 8, 14);
                    c.quadraticCurveTo(7.5, 8.5, 2, 8);
                    c.quadraticCurveTo(7.5, 7.5, 8, 2);
                    c.moveTo(14, 12);
                    c.lineTo(14, 16);
                    c.moveTo(12, 14);
                    c.lineTo(16, 14);
                    break;
                case "close":
                    c.moveTo(5, 5);
                    c.lineTo(13, 13);
                    c.moveTo(13, 5);
                    c.lineTo(5, 13);
                    break;
                case "minus":
                    c.moveTo(4, 9);
                    c.lineTo(14, 9);
                    break;
                case "plus":
                    c.moveTo(4, 9);
                    c.lineTo(14, 9);
                    c.moveTo(9, 4);
                    c.lineTo(9, 14);
                    break;
                default:
                    for (let x = 3; x <= 15; x += 6) {
                        c.moveTo(x + 1, 9);
                        c.arc(x, 9, 1, 0, Math.PI * 2);
                    }
                }
                c.stroke();
            }
        }
        Rectangle {
            anchors.bottom: parent.bottom
            anchors.horizontalCenter: parent.horizontalCenter
            width: 16
            height: 3
            color: root.swatch
            visible: root.swatch.a > 0
        }
    }
    onKindChanged: icon.requestPaint()
    onTintChanged: icon.requestPaint()
}
