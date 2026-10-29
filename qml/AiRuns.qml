import QtQuick

// The answers being written, app-wide, for every view of a conversation (the AI panel, chat tabs). It alone listens
// to the AI service, keeps each answer's text as it comes, then tells the views: a view showing that conversation
// shows that answer, whichever view asked. Questions asked meanwhile wait here, per conversation, and go from here.
QtObject {
    id: root
    readonly property var ai: researchStore.ai
    // By request: {threadId, question, answer, thinking, thinkingSeconds, askedAt, model, truncated, translatePage}.
    // Text changes in place; the map is replaced only when one starts, ends or learns its conversation.
    property var running: ({})
    readonly property var answeringThreads: Object.keys(running).map(function(k) { return running[k].threadId }).filter(function(t) { return t.length })
    // What went wrong in a conversation no view was showing, said when one opens it.
    property var failures: ({})
    // Questions asked while an answer was still coming, by conversation ("" for a new one not saved yet), each with
    // the model chosen then: the next goes once the answer before it is done. After a Stop or a failure they wait,
    // each with Send. Kept only while Owelk runs.
    property var queued: ({})
    // After the views have taken the answer that ended.
    signal started(int id, string thread)
    signal thinking(int id, string text)
    signal delta(int id, string text)
    signal finished(int id, string thread, string text, var details)
    signal failed(int id, string thread, string message)
    // An answer saved (the "answer ready" card is shown unless it is in view).
    signal answered(string threadId, string title, string preview)

    function setRunning(id, entry) {
        const next = Object.assign({}, running)
        if (entry) next[id] = entry
        else delete next[id]
        running = next
    }
    // A question just asked by a view: its answer is followed from here.
    function asked(id, entry) { setRunning(id, entry) }
    function setQueued(key, list) {
        const next = Object.assign({}, queued)
        if (list.length) next[key] = list
        else delete next[key]
        queued = next
    }
    function consumeFailure(thread) {
        if (!failures[thread]) return ""
        const message = failures[thread]
        const left = Object.assign({}, failures); delete left[thread]; failures = left
        return message
    }
    // What a saved chat goes on asking: its paper (already in the conversation) and, when its last question
    // searched a collection, the library or several papers, the same again.
    function continuing(saved) {
        const next = saved.source && saved.source.toString().length ? {source: saved.source, scope: "none"} : ({})
        const asked = (saved.messages || []).filter(function(m) { return m.role === "user" })
        const context = asked.length ? asked[asked.length - 1].context || {} : {}
        if ((context.attachments || []).indexOf("library") < 0) return next
        const papers = (context.searchUrls || []).filter(function(url) { return !next.source || !researchStore.sameSource(next.source, url) })
        if (context.wholeLibrary) Object.assign(next, {scope: "library", collection: "", collectionName: ""})
        else if (context.collection) Object.assign(next, {scope: "library", collection: context.collection, collectionName: context.collectionName || ""})
        else if (papers.length) next.searchPapers = true
        if (papers.length) next.papers = papers
        return next
    }
    // An answer in a line, for the "answer ready" card.
    function preview(text) { return text.replace(/\]\([^)]*\)/g, "]").replace(/[#*_`>|]/g, "").replace(/\s+/g, " ").trim().slice(0, 160) }
    // The next waiting question of a conversation whose answer has just come, a moment later (once the views have
    // let the answer go, so they take the new one).
    property var nextThreads: []
    readonly property Timer nextLater: Timer { interval: 0; onTriggered: { const list = root.nextThreads; root.nextThreads = []; list.forEach(root.sendNext) } }
    function sendNext(thread) {
        const list = queued[thread] || []
        if (!list.length) return
        const item = list[0]
        setQueued(thread, list.slice(1))
        const saved = researchStore.aiThread(thread)
        if (!saved.id || saved.trashed) return
        const choice = {provider: item.provider, model: item.model, question: item.question, threadId: thread, action: "ask",
                        imageFiles: [], imageLabels: [], imageNames: []}
        if (item.effort) choice.effort = item.effort
        if (item.fast) choice.fast = true
        const id = ai.ask(Object.assign({}, continuing(saved), choice))
        setRunning(id, {threadId: thread, question: item.question, answer: "", thinking: "", thinkingSeconds: 0,
                        askedAt: Date.now(), model: "", truncated: false, translatePage: -1})
    }

    readonly property Connections service: Connections {
        target: root.ai
        function onStarted(id, thread, provider, model, cut) {
            const r = root.running[id]
            if (r) {
                root.setRunning(id, Object.assign({}, r, {threadId: thread, model: model, truncated: cut}))
                // Questions waiting on a new conversation's first answer now wait on its thread.
                if (!r.threadId.length && thread.length && root.queued[""]) {
                    root.setQueued(thread, (root.queued[thread] || []).concat(root.queued[""]))
                    root.setQueued("", [])
                }
            }
            root.started(id, thread)
        }
        function onThinking(id, text) {
            const r = root.running[id]
            if (r) r.thinking += text
            root.thinking(id, text)
        }
        function onDelta(id, text) {
            const r = root.running[id]
            if (r) {
                if (!r.answer.length) r.thinkingSeconds = Math.max(1, Math.round((Date.now() - r.askedAt) / 1000))
                r.answer += text
            }
            root.delta(id, text)
        }
        function onFinished(id, text, details) {
            const r = root.running[id]
            if (!r) { root.finished(id, "", text, details); return }
            root.setRunning(id, null)
            root.finished(id, r.threadId, text, details)
            if (!r.threadId.length) return
            root.answered(r.threadId, researchStore.aiThread(r.threadId).title || "AI", root.preview(text))
            if (!details.stopped) { root.nextThreads = root.nextThreads.concat([r.threadId]); root.nextLater.restart() }
        }
        function onFailed(id, message) {
            const r = root.running[id]
            if (!r) { root.failed(id, "", message); return }
            root.setRunning(id, null)
            if (r.threadId.length && message !== "Stopped.") {
                const next = Object.assign({}, root.failures); next[r.threadId] = message; root.failures = next
            }
            root.failed(id, r.threadId, message)
        }
    }
}
