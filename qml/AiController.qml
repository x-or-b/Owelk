import Owelk.Ui
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "AiNames.js" as AiNames
import "WorkspaceTree.js" as Tree

// The AI conversation behind the AI panel. Lives outside the dock so switching panels or docks
// never drops a streaming answer. Every turn is kept as a thread; follow-ups send earlier turns along.
Item {
    id: root
    objectName: "aiController"
    visible: false
    readonly property var ai: researchStore.ai
    property var reader: null
    // The tabs (DocumentWorkspace): PDFs open in them come first when attaching papers.
    property var workspace: null
    function openTabPapers() {
        if (!workspace || !workspace.tree) return []
        const seen = {}, list = []
        Tree.leaves(workspace.tree).forEach(function(group) {
            group.tabs.forEach(function(tab) {
                if (tab.kind || !tab.source || seen[tab.source]) return
                seen[tab.source] = true
                list.push(tab.source)
            })
        })
        return list
    }
    property string threadId: ""
    property var thread: ({})
    readonly property var messages: thread.messages || []
    // What the next request carries (source, scope, page, selection, quote, action).
    property var spec: ({})
    // The page last translated on its own, so the panel can offer the next one (-1: none).
    property int translatePage: -1
    readonly property bool canTranslateNext: translatePage >= 0 && !streaming && !!reader && reader.pdfReady
                                             && translatePage + 1 < reader.pageCount && !!spec.source
    function translateNext() {
        if (!canTranslateNext) return false
        const page = translatePage + 1
        spec = {action: "translate", scope: "page", page: page, source: spec.source, fresh: true, label: "Translate page " + (page + 1)}
        return send("")
    }
    property int request: -1
    property string pendingQuestion: ""
    property string answer: ""
    property string error: ""
    property string usedModel: ""
    property bool truncated: false
    property bool streaming: false
    // The reasoning summary of the answer being prepared, and the seconds before the answer began.
    property string thinkingText: ""
    property int thinkingSeconds: 0
    property double askedAt: 0
    property bool showThinking: researchStore.setting("ai.showThinking", "1") === "1"
    // Settings → AI may change these too.
    Connections { target: researchStore; function onSettingsChanged() { root.showThinking = researchStore.setting("ai.showThinking", "1") === "1"; root.loadSelection() } }
    // One line for "Thinking · …": the latest heading of the summary, else its latest sentence.
    function thinkingHeadline(text) {
        const headings = text.match(/\*\*([^*\n]+)\*\*/g) || []
        let line = headings.length ? headings[headings.length - 1] : ""
        if (!line.length) {
            const paragraphs = text.split(/\n+/).map(function(p) { return p.trim() }).filter(function(p) { return p.length })
            const last = paragraphs.length ? paragraphs[paragraphs.length - 1] : ""
            const sentences = last.split(/[.!?]\s+/).filter(function(p) { return p.trim().length > 12 })
            line = sentences.length ? sentences[sentences.length - 1] : last
        }
        line = line.replace(/[*_`#>]/g, "").replace(/\s+/g, " ").trim()
        return line.length > 120 ? line.slice(0, 119) + "…" : line
    }
    // provider id → [{id, name}] as the providers report them.
    property var models: ({})
    // Whether a conversation is open (a saved chat or a new one); otherwise the AI panel waits empty and
    // the first question starts one about the paper in the reader.
    property bool conversationOpen: false
    signal focusRequested()
    // An answer came in: the thread, its title and the answer's opening words (plain text).
    signal answered(string threadId, string title, string preview)
    readonly property var providerInfo: ai.providers.find(function(p) { return p.id === ai.provider }) || ({})
    // The model choice for the next turn: provider and model are the service's; effort and fast
    // mode are remembered per provider and offered only where the model supports them.
    readonly property string model: (ai.providers, ai.model(ai.provider))
    readonly property var modelInfo: (models[ai.provider] || []).find(function(m) { return m.id === root.model }) || ({})
    readonly property string modelLabel: modelInfo.name || model || (ai.provider === "codex" ? qsTr("Default model") : qsTr("Choose a model"))
    readonly property var efforts: modelInfo.efforts || []
    property string effort: ""
    property bool fast: false
    readonly property string effectiveEffort: efforts.indexOf(effort) >= 0 ? effort : (modelInfo.defaultEffort || (efforts.length ? efforts[0] : ""))
    readonly property bool fastAvailable: !!modelInfo.fast
    readonly property bool effectiveFast: fast && fastAvailable
    // Images attached to the next question: [{url, name}].
    property var images: []
    // A region of the PDF dragged out from the AI panel: its picture joins the next question (nothing is
    // saved; the reader sends it back through begin({attach, region})).
    function captureRegion() {
        if (!reader || !reader.pdfReady) { error = qsTr("Open a PDF to choose a region."); return false }
        error = ""
        reader.startCapture()
        return true
    }
    readonly property string selectionProvider: ai.provider
    onSelectionProviderChanged: { loadSelection(); checkAccount() }
    Component.onCompleted: { loadSelection(); loadModels(); checkAccount() }
    // The ChatGPT sign-in lives with Codex and survives quitting; ask Codex again at start and on switching
    // to it, or the account would look signed out until Settings › AI is opened.
    function checkAccount() { if (ai.provider === "codex" && !providerInfo.configured) ai.refreshCodexAccount() }
    // Once the account is known, its models come too.
    Connections { target: root.ai; function onProvidersChanged() { if (root.ai.provider === "codex" && root.providerInfo.configured && !root.models.codex) root.ai.listModels("codex") } }
    function loadSelection() {
        effort = researchStore.setting("ai.effort." + ai.provider, "")
        fast = researchStore.setting("ai.fast." + ai.provider, "") === "1"
    }
    function setEffort(value) { effort = value; researchStore.setSetting("ai.effort." + ai.provider, value) }
    function setFast(on) { fast = on; researchStore.setSetting("ai.fast." + ai.provider, on ? "1" : "") }
    function effortName(value) { return AiNames.effortName(value) }
    function companyName(provider) {
        return ({claude: qsTr("Anthropic"), openai: qsTr("OpenAI"), codex: qsTr("ChatGPT account"), ollama: qsTr("Ollama (this computer)")})[provider] || provider
    }
    function attachImage(url, name, about) {
        const value = url.toString()
        if (!/\.(png|jpe?g|gif|webp|heic)$/i.test(value) || images.some(function(i) { return i.url === value })) return false
        if (images.length >= 6) { error = qsTr("Up to 6 images per question."); return false }
        images = images.concat([{url: value, name: name || decodeURIComponent(value.replace(/^.*\//, "")), about: about || ""}])
        return true
    }
    // A figure, table, algorithm, equation or marked region from the PDF: its image, named so the model
    // knows what it is ("Figure 3, page 5"), joins the open conversation, or a new one about that paper.
    function attachFigure(next) {
        const file = ai.saveRegionImage(next.source, next.page, next.region)
        if (!file.length) { error = qsTr("Could not read that part of the PDF."); return false }
        if (!conversationOpen) newThread(next.source)
        const label = next.label || "Figure", page = Number(next.page) + 1
        const elsewhere = spec.source && !researchStore.sameSource(spec.source, next.source)
        if (!attachImage(file, label + " · p. " + page,
                         label + ", page " + page + (elsewhere ? " of " + researchStore.displayName(next.source) : ""))) return false
        focusRequested()
        return true
    }
    // A picture from elsewhere (part of a web page), already saved: attached as it is.
    function attachPicture(next) {
        if (!conversationOpen) newThread("")
        if (!attachImage(next.image, next.name, next.about)) return false
        focusRequested()
        return true
    }
    // Words selected in the PDF, to ask about: with the open conversation, or a new one.
    function attachText(next) {
        if (!conversationOpen) newThread(next.source)
        const elsewhere = spec.source && !researchStore.sameSource(spec.source, next.source)
        const text = (elsewhere ? "(From " + researchStore.displayName(next.source) + ", page " + (Number(next.page) + 1) + ")\n" : "") + next.selection
        spec = Object.assign({}, spec, {selection: text})
        focusRequested()
        return true
    }
    function pasteImage() {
        const file = ai.saveClipboardImage()
        return file.length > 0 && attachImage(file)
    }
    readonly property var actions: ({translate: "Translate", ask: "Ask"})
    // What goes into the request, shown as chips before anything is sent.
    readonly property var attachments: {
        const list = []
        const s = spec
        // The paper chip is the paper itself: with no narrower scope (a page, a selection) its whole text
        // goes with the first question; later turns carry it in the conversation.
        if (s.source && s.source.toString().length) list.push({kind: "paper", label: qsTr("Paper · ") + researchStore.displayName(s.source)})
        if (s.selection && s.selection.length) {
            const flat = s.selection.replace(/\s+/g, " ").trim()
            list.push({kind: "selection", label: qsTr("Selection · ") + flat.slice(0, 60) + (flat.length > 60 ? "…" : ""), detail: s.selection})
        }
        if (s.quote && s.quote.length) {
            const flat = s.quote.replace(/\s+/g, " ").trim()
            list.push({kind: "quote", label: qsTr("Quote · ") + flat.slice(0, 60) + (flat.length > 60 ? "…" : ""), detail: s.quote})
        }
        if (s.scope === "page") list.push({kind: "page", label: qsTr("Page ") + (Number(s.page) + 1) + qsTr(" text")})
        ;(s.papers || []).forEach(function(url, index) { list.push({kind: "extra", index: index, label: qsTr("Paper · ") + researchStore.displayName(url)}) })
        if (s.scope === "library") list.push({kind: "library", label: (s.collection ? qsTr("Collection · ") + s.collectionName : qsTr("Whole library")) + qsTr(" · passages that answer the question")})
        else if (searchesPapers(s)) list.push({kind: "passages", fixed: true, label: qsTr("Several papers · passages that answer the question")})
        ;(s.noteIds || []).forEach(function(id, index) { list.push({kind: "note", index: index, label: qsTr("Note · ") + (researchStore.note(id).title || qsTr("Untitled note"))}) })
        images.forEach(function(image, index) { list.push({kind: "image", index: index, label: image.name, url: image.url}) })
        return list
    }
    // A note to talk about (or have rewritten): its text goes with the next question.
    function attachNote(id) {
        ensureConversation()
        const next = Object.assign({}, spec), list = (next.noteIds || []).slice()
        if (list.indexOf(id) < 0 && list.length < 10) list.push(id)
        else if (list.length >= 10) error = qsTr("Up to 10 notes per question.")
        next.noteIds = list
        spec = next
        focusRequested()
    }
    // Notes chosen in the Library: a new chat about them (no paper unless one is added).
    function attachNotes(ids) {
        reset()
        threadId = ""; thread = ({}); spec = ({})
        conversationOpen = true
        ids.forEach(function(id) { attachNote(id) })
    }
    // Notes an answer proposes (<note_update id title>…</note_update>, <note_new title>…</note_new>): the
    // answer's text without them, the notes, its text with each note's Markdown in place (to copy or save),
    // and whether one is still being written (while streaming).
    function noteBlocks(content) {
        const notes = [], value = function(attrs, name) {
            const m = new RegExp(name + '="([^"]*)"').exec(attrs)
            return m ? m[1].replace(/&quot;/g, '"').replace(/&amp;/g, "&") : ""
        }
        const pattern = /<note_(update|new)\b([^>]*)>([\s\S]*?)<\/note_\1>/g
        let text = content || "", plain = text
        text = text.replace(pattern, function(all, kind, attrs, body) {
            notes.push({kind: kind, id: kind === "update" ? value(attrs, "id") : "", title: value(attrs, "title"), body: body.replace(/^\n+|\s+$/g, "")})
            return ""
        })
        plain = plain.replace(pattern, function(all, kind, attrs, body) { return body.trim() })
        const open = text.search(/<note_(update|new)\b/)
        const preparing = open >= 0
        if (preparing) { text = text.slice(0, open); plain = plain.slice(0, plain.search(/<note_(update|new)\b/)) }
        return {text: text.trim(), plain: plain.trim(), notes: notes, preparing: preparing}
    }
    // Proposals applied in this session (by thread, answer and block), for Open and Undo.
    property var appliedNotes: ({})
    function noteKey(index, n) { return threadId + ":" + index + ":" + n }
    // Applies a proposed note: the attached note rewritten (Undo puts it back), or a new note that links
    // to this conversation and its paper.
    function applyNote(index, n) {
        const block = noteBlocks((messages[index] || {}).content).notes[n]
        if (!block) return ""
        const key = noteKey(index, n), done = Object.assign({}, appliedNotes)
        const existing = block.kind === "update" && block.id.length ? researchStore.note(block.id) : ({})
        if (existing.id && !existing.deleted) {
            const before = researchStore.replaceNote(block.id, block.title, block.body)
            if (!before.body && before.body !== "") return ""
            done[key] = {noteId: block.id, before: before}
            appliedNotes = done
            researchStore.notify(qsTr("Note updated."))
            return block.id
        }
        const lines = [block.body, "", "---", "- " + researchStore.markdownLink("ai", threadId)]
        if (thread.source && thread.source.toString().length) {
            const paper = researchStore.documentLinkId(thread.source)
            if (paper.length) lines.push("- " + researchStore.markdownLink("document", paper))
        }
        const id = researchStore.createNote(block.title || thread.title || "AI", lines.join("\n") + "\n")
        if (!id.length) return ""
        done[key] = {noteId: id, created: true}
        appliedNotes = done
        researchStore.notify(qsTr("Note created."))
        return id
    }
    function undoNote(index, n) {
        const key = noteKey(index, n), applied = appliedNotes[key]
        if (!applied || !applied.before) return false
        if (!Object.keys(researchStore.replaceNote(applied.noteId, applied.before.title, applied.before.body)).length) return false
        const done = Object.assign({}, appliedNotes)
        delete done[key]
        appliedNotes = done
        researchStore.notify(qsTr("Note restored."))
        return true
    }
    // Several papers are read whole up to three; past that (or once a chat has searched them) each question
    // gets the passages that answer it, as for a collection (AiService::ask).
    function searchesPapers(s) {
        const reads = (s.scope === "paper" && s.source && s.source.toString().length ? 1 : 0) + (s.papers || []).length
        return s.scope !== "library" && (reads > 3 || (!!s.searchPapers && (s.papers || []).length > 0))
    }
    // Papers chosen to go with the next question: open tabs, the Library, drops. The first becomes the chat's
    // own paper when it has none yet; the rest are P2, P3… for citations.
    function attachPapers(urls) {
        ensureConversation()
        const next = Object.assign({}, spec), list = (next.papers || []).slice()
        for (const value of urls) {
            const url = value.toString()
            if (!/\.pdf$/i.test(url) && !/^file:/.test(url)) continue
            if (next.source && next.source.toString().length && researchStore.sameSource(next.source, url)) continue
            if ((!next.source || !next.source.toString().length) && next.scope !== "library") { next.source = url; next.scope = "paper"; continue }
            if (list.indexOf(url) < 0 && list.length < 40) list.push(url)
        }
        next.papers = list
        spec = next
        focusRequested()
    }
    // A collection (id and name), or the whole library (no id): each question gets the passages that answer it.
    function attachCollection(id, name) {
        ensureConversation()
        const next = Object.assign({}, spec)
        next.scope = "library"; next.collection = id || ""; next.collectionName = name || ""
        delete next.page
        spec = next
        focusRequested()
    }
    // The answers being written and the questions waiting, shared by every view of a conversation (AiRuns): this
    // one shows its conversation's, whichever view asked.
    property var runs: null
    readonly property var running: runs ? runs.running : ({})
    readonly property var answeringThreads: runs ? runs.answeringThreads : []
    function continuing(saved) { return runs.continuing(saved) }
    readonly property var queuedHere: runs ? runs.queued[threadId] || [] : []
    // Asked while an answer is still coming: it goes next (from AiRuns), with the model chosen now.
    function queue(question) {
        const text = question.trim()
        if (!text.length || !runs) return false
        const item = {question: text, provider: ai.provider, model: model, effort: efforts.length ? effectiveEffort : "", fast: effectiveFast}
        runs.setQueued(threadId, queuedHere.concat([item]))
        return true
    }
    function unqueue(index) { runs.setQueued(threadId, queuedHere.filter(function(_, i) { return i !== index })) }
    // A waiting one sent now (the conversation open and nothing coming).
    function sendQueued(index) {
        if (streaming || index < 0 || index >= queuedHere.length) return false
        const item = queuedHere[index]
        unqueue(index)
        return send(item.question)
    }
    // Stop is for the answer shown; moving to another conversation leaves it writing.
    function stop() { if (streaming) ai.cancel(request) }
    function reset() {
        request = -1; streaming = false
        answer = ""; error = ""; pendingQuestion = ""; usedModel = ""; truncated = false
        thinkingText = ""; thinkingSeconds = 0; translatePage = -1
    }
    // The open conversation's answer still being written (or what went wrong with it), shown again.
    function showRunning() {
        if (!threadId.length || !runs) return
        const failure = runs.consumeFailure(threadId)
        if (failure.length) error = failure
        for (const key in runs.running) {
            const r = runs.running[key]
            if (r.threadId !== threadId) continue
            request = Number(key); streaming = true
            pendingQuestion = r.question; answer = r.answer; thinkingText = r.thinking; thinkingSeconds = r.thinkingSeconds
            askedAt = r.askedAt; usedModel = r.model; truncated = r.truncated; translatePage = r.translatePage
            return
        }
    }
    // Attaching (a figure or region, the selection, a picture) adds to the conversation open in the AI panel, even
    // while the panel is hidden, or starts one; a page translation starts its own thread.
    function begin(next) {
        if (next.attach) {
            if (next.region) attachFigure(next)
            else if (next.image) attachPicture(next)
            else if (next.selection) attachText(next)
            else if (next.note) attachNote(next.note)
            else if (next.notes) attachNotes(next.notes)
            return
        }
        reset()
        threadId = ""; thread = ({})
        conversationOpen = true
        spec = Object.assign({}, next)
        if (spec.action === "ask") focusRequested()
        else send("")
    }
    // A new conversation about the given paper (or the one in the reader); kept in the given Thread (folder)
    // rather than its paper's.
    function newThread(source, folder) {
        reset()
        threadId = ""; thread = ({})
        const paper = source !== undefined && source.toString().length ? source : reader && reader.source ? reader.source : ""
        spec = paper.toString().length ? {source: paper, scope: "paper", page: reader && researchStore.sameSource(reader.source, paper) ? reader.currentPage || 0 : 0} : ({})
        if (folder) spec.folder = folder
        conversationOpen = true
        focusRequested()
    }
    function openThread(id) {
        const saved = researchStore.aiThread(id)
        if (!saved.id) return false
        reset()
        threadId = id; thread = saved
        researchStore.markOpened("ai", id)
        conversationOpen = true
        // Continue with the model the thread used, when that provider is still set up.
        const info = ai.providers.find(function(p) { return p.id === saved.provider }) || ({})
        if (info.configured || saved.provider === "ollama") {
            ai.provider = saved.provider
            if (saved.model) ai.setModel(saved.provider, saved.model)
        }
        spec = runs.continuing(saved)
        showRunning()
        return true
    }
    // The AI panel's question box was reached with nothing open: a new chat about the paper in the reader.
    function ensureConversation() {
        if (conversationOpen) return
        threadId = ""; thread = ({})
        spec = reader && reader.source && reader.source.toString().length ? {source: reader.source, scope: "paper", page: reader.currentPage || 0} : ({})
        conversationOpen = true
    }
    // This paper again, after its chip was removed.
    function attachPaper() {
        if (!reader || !reader.source.toString().length) return
        // A chat about another paper takes this one as one more.
        if (spec.source && spec.source.toString().length && !researchStore.sameSource(spec.source, reader.source)) { attachPapers([reader.source]); return }
        spec = Object.assign({}, spec, {source: reader.source, scope: "paper"})
    }
    // A passage from an answer (Ask About This), sent with the next question as its own material.
    function quote(text) {
        const next = Object.assign({}, spec)
        next.quote = text.trim().slice(0, 4000)
        if (next.quote.length) spec = next
        focusRequested()
    }
    function detach(kind, index) {
        if (kind === "image") { images = images.filter(function(_, i) { return i !== index }); return }
        const next = Object.assign({}, spec)
        // Without the paper the question goes out on its own: no paper details, page or selection.
        if (kind === "paper") {
            delete next.source; delete next.page; delete next.selection
            if (next.scope === "page" || next.scope === "paper" || next.scope === "selection") next.scope = "none"
            spec = next
            return
        }
        if (kind === "quote") delete next.quote
        if (kind === "note") next.noteIds = (next.noteIds || []).filter(function(_, i) { return i !== index })
        if (kind === "extra") next.papers = (next.papers || []).filter(function(_, i) { return i !== index })
        // Without the collection: the chat's paper again (already in the conversation, or read now), else the
        // one in the reader.
        if (kind === "library") {
            delete next.collection; delete next.collectionName
            if (!next.source || !next.source.toString().length) {
                if (reader && reader.source && reader.source.toString().length) next.source = reader.source
            }
            const inThread = next.source && thread.source && researchStore.sameSource(thread.source, next.source)
            next.scope = !next.source || !next.source.toString().length ? "none" : inThread ? "none" : "paper"
        }
        if (kind === "selection") next.selection = ""
        if (kind === "page") next.scope = "none"
        spec = next
    }
    function send(question) {
        ensureConversation()
        error = ""
        if (thread.trashed) { error = qsTr("Restore this conversation to continue it."); return false }
        const provider = ai.provider
        if (!providerInfo.configured && provider !== "ollama") {
            error = setupHint(provider)
            return false
        }
        if (!spec.action && !question.trim().length) return false
        if (!ai.consented(provider)) { consent.question = question; consent.open(); return false }
        pendingQuestion = question.trim().length ? question.trim() : (spec.label || actions[spec.action] || "Ask")
        translatePage = !question.trim().length && spec.action === "translate" && spec.scope === "page" ? Number(spec.page) : -1
        answer = ""; streaming = true
        thinkingText = ""; thinkingSeconds = 0; askedAt = Date.now()
        const choice = {provider: provider, model: model, question: question, threadId: threadId, action: spec.action || "ask",
                        imageFiles: images.map(function(i) { return i.url }),
                        imageLabels: images.map(function(i) { return i.about || "" }),
                        imageNames: images.map(function(i) { return i.name || "" })}
        if (efforts.length) choice.effort = effectiveEffort
        if (effectiveFast) choice.fast = true
        request = ai.ask(Object.assign({}, spec, choice))
        runs.asked(request, {threadId: threadId, question: pendingQuestion, answer: "", thinking: "", thinkingSeconds: 0,
                             askedAt: askedAt, model: "", truncated: false, translatePage: translatePage})
        images = []
        return true
    }
    function loadModels() {
        for (const p of ai.providers)
            if (p.configured || p.id === "ollama") ai.listModels(p.id)
    }
    // Where a provider that cannot answer yet is set up.
    function setupHint(provider) {
        if (provider === "codex") return qsTr("Sign in with ChatGPT in Settings → AI.")
        return qsTr("Add an API key in Settings → AI.")
    }
    function chooseModel(provider, model) {
        ai.provider = provider
        ai.setModel(provider, model)
    }
    // Closes the open conversation (the panel waits empty).
    function showThreads() {
        reset()
        images = []
        threadId = ""; thread = ({}); spec = ({})
        conversationOpen = false
    }
    function renameThread(id, title) { return researchStore.renameAiThread(id, title) }
    // A conversation opened from a note while it is in the Trash comes back to the threads.
    function restoreThread() {
        if (!threadId.length || !researchStore.trashAiThreads([threadId], false)) return false
        thread = researchStore.aiThread(threadId)
        return true
    }
    // Notes about the paper this conversation is about: where an answer can be added.
    function paperNotes() {
        if (!thread.source || !thread.source.toString().length) return []
        return researchStore.backlinks("document", researchStore.documentLinkId(thread.source)).filter(function(b) { return b.kind === "note" })
    }
    // An answer as a note: the question quoted above it, then links to the conversation and the paper.
    // Into a new note, or added to the end of one (noteId).
    function saveAsNote(index, noteId) {
        const message = messages[index]
        if (!message || message.role !== "assistant" || !threadId.length) return ""
        const asked = index > 0 && messages[index - 1].role === "user" ? (messages[index - 1].display || messages[index - 1].content || "").trim() : ""
        const lines = asked.length ? ["> " + asked.split("\n").join("\n> "), ""] : []
        lines.push(noteBlocks(message.content).plain, "", "---", "- " + researchStore.markdownLink("ai", threadId))
        if (thread.source && thread.source.toString().length) {
            const paper = researchStore.documentLinkId(thread.source)
            if (paper.length) lines.push("- " + researchStore.markdownLink("document", paper))
        }
        const text = lines.join("\n")
        const note = noteId ? (researchStore.appendToNote(noteId, text) ? noteId : "") : researchStore.createNote(thread.title || "AI", text + "\n")
        if (note.length) researchStore.notify(noteId ? qsTr("Added to the note.") : qsTr("Saved as a note with links to its sources."))
        return note
    }
    // The answers come by way of AiRuns, which has their conversation and text by then.
    Connections {
        target: root.runs
        function onStarted(id, thread) {
            if (id === root.request) {
                const r = root.runs.running[id] || ({})
                root.usedModel = r.model || ""; root.truncated = !!r.truncated
                if (root.threadId !== thread) { root.threadId = thread; root.thread = researchStore.aiThread(thread); researchStore.markOpened("ai", thread) }
                return
            }
            // Asked in another view of this conversation, or its next waiting question: shown here too.
            if (thread.length && thread === root.threadId && !root.streaming) root.showRunning()
        }
        function onThinking(id, text) { if (id === root.request) root.thinkingText += text }
        function onDelta(id, text) {
            if (id !== root.request) return
            if (!root.answer.length) root.thinkingSeconds = Math.max(1, Math.round((Date.now() - root.askedAt) / 1000))
            root.answer += text
        }
        function onFinished(id, thread, text, details) {
            if (id !== root.request) return
            root.streaming = false; root.usedModel = details.model
            root.thread = researchStore.aiThread(root.threadId)
            root.answer = ""; root.pendingQuestion = ""; root.thinkingText = ""
            // The material went with this turn; follow-ups reuse it through the thread. What is searched (a
            // collection, the library, several papers) is searched again for each question.
            const sent = root.spec, searched = sent.scope === "library" || root.searchesPapers(sent)
            const next = sent.source ? {source: sent.source, scope: "none"} : ({})
            if (sent.scope === "library") Object.assign(next, {scope: "library", collection: sent.collection || "", collectionName: sent.collectionName || ""})
            else if (searched) next.searchPapers = true
            if (searched && (sent.papers || []).length) next.papers = sent.papers
            root.spec = next
            // Another answer for this conversation already coming (asked in another view).
            root.showRunning()
        }
        function onFailed(id, thread, message) {
            if (id !== root.request) return
            root.streaming = false
            if (message !== "Stopped.") { root.error = message; root.runs.consumeFailure(thread) }
        }
        function onAnswered(threadId, title, preview) { root.answered(threadId, title, preview) }
    }
    Connections {
        target: root.ai
        function onModelsLoaded(provider, list) {
            const next = Object.assign({}, root.models)
            next[provider] = list
            root.models = next
        }
    }
    Connections {
        target: researchStore
        function onAiThreadsChanged() {
            if (root.threadId.length && !root.streaming) {
                const saved = researchStore.aiThread(root.threadId)
                // Another conversation changed (an answer finished in the background): this one is read again only
                // when it changed, so its view does not start over.
                if (saved.id) { if (JSON.stringify(saved) !== JSON.stringify(root.thread)) root.thread = saved }
                else { root.threadId = ""; root.thread = ({}) }
            }
        }
    }
    Dialog {
        id: consent
        objectName: "aiConsentDialog"
        parent: Overlay.overlay
        anchors.centerIn: parent
        width: 440
        modal: true
        property string question: ""
        title: qsTr("Send to ") + (root.providerInfo.name || qsTr("AI provider")) + "?"
        standardButtons: Dialog.Ok | Dialog.Cancel
        ColumnLayout {
            width: parent.width
            spacing: 8
            Label {
                Layout.fillWidth: true; wrapMode: Text.Wrap
                text: qsTr("Owelk sends the parts shown below and the earlier turns of this thread to ") + (root.providerInfo.sends || qsTr("the provider"))
                      + qsTr(" each time you ask. Nothing else from your library leaves this computer, and the PDF file itself is never uploaded.")
            }
            Repeater {
                model: root.attachments
                delegate: Label { required property var modelData; text: "• " + modelData.label; color: Theme.textSecondary; elide: Text.ElideRight; Layout.fillWidth: true }
            }
            Label { Layout.fillWidth: true; wrapMode: Text.Wrap; font.pixelSize: Theme.fontSmall; color: Theme.textTertiary; text: qsTr("You are asked once per provider. Usage is billed by the provider under your account.") }
        }
        onAccepted: { root.ai.giveConsent(root.ai.provider); root.send(question) }
    }
}
