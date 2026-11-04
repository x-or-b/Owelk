import QtQuick
import QtWebEngine

// The profile every web tab shares, kept in the data folder (cookies, logins, cache).
// Qt 6.11 suggests WebEngineProfilePrototype, but instance() hung page loads in offscreen tests;
// revisit when the plain profile type is actually deprecated.
WebEngineProfile {
    storageName: "owelk"
    offTheRecord: false
    persistentStoragePath: researchStore.dataDirectory + "/web"
    cachePath: researchStore.dataDirectory + "/web/cache"
    httpCacheType: WebEngineProfile.DiskHttpCache
    persistentCookiesPolicy: WebEngineProfile.AllowPersistentCookies
    // Present as plain Chrome: publisher sites (IEEE and the like) slow down or challenge browsers
    // whose name carries "QtWebEngine".
    Component.onCompleted: httpUserAgent = httpUserAgent.replace(/\s*QtWebEngine\/[\d.]+/, "")
}
