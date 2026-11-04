import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Owelk.Ui

// A web tab where Owelk has no web engine (iPadOS, Android): the page opens in the system browser. It offers what
// the workspace uses of a desktop web tab (qml/WebPane.qml): the tab, its address and an empty history.
Rectangle {
    id: root
    objectName: "webPane"
    required property var controller
    property string tabId: ""
    property bool isActive: false
    property bool frozen: false
    property string openedUrl: ""
    // What the workspace reads from a page (Back and Forward stay off: there is no history here).
    readonly property QtObject view: QtObject {
        property url url
        property string title
        readonly property bool canGoBack: false
        readonly property bool canGoForward: false
        function goBack() {}
        function goForward() {}
        function reload() {}
    }
    property bool capturing: false
    signal downloadStarted(string fileName)
    signal activated()
    color: Theme.content
    function open(url) {
        openedUrl = url.toString()
        view.url = url
        if (tabId.length) controller.updateWebTab(tabId, openedUrl, "")
    }
    function focusAddress() {}
    function captureRegion(rect) { capturing = false }
    TapHandler { onTapped: root.activated() }
    ColumnLayout {
        anchors.centerIn: parent
        width: Math.min(parent.width - 48, 420)
        spacing: 12
        Label {
            Layout.fillWidth: true
            text: qsTr("Web pages open in the browser on this device.")
            color: Theme.textSecondary; wrapMode: Text.Wrap; horizontalAlignment: Text.AlignHCenter
        }
        Label {
            Layout.fillWidth: true
            text: root.openedUrl
            color: Theme.textTertiary; elide: Text.ElideMiddle; horizontalAlignment: Text.AlignHCenter
        }
        Button {
            Layout.alignment: Qt.AlignHCenter
            objectName: "webOpenInBrowser"
            text: qsTr("Open in Browser"); primary: true
            enabled: root.openedUrl.length > 0
            onClicked: Qt.openUrlExternally(root.openedUrl)
        }
    }
}
