#pragma once

#include <QHash>
#include <QObject>
#include <QPointer>
#include <QVariantList>
#include <QVariantMap>

class AiProvider;
class CodexBridge;
class QNetworkAccessManager;
class ResearchStore;

// Reading help from an AI provider: builds the request from the paper, page, selection, captures and
// notes, streams the answer, and keeps keys in the Keychain. Nothing is sent before the user agreed
// to what a provider receives (consent is per provider).
class AiService final : public QObject {
    Q_OBJECT
    Q_PROPERTY(QVariantList providers READ providers NOTIFY providersChanged)
    Q_PROPERTY(QString provider READ provider WRITE setProvider NOTIFY providersChanged)
    Q_PROPERTY(bool busy READ busy NOTIFY busyChanged)
public:
    explicit AiService(ResearchStore *store, QObject *parent = nullptr);
    ~AiService() override;
    // id, name, kind (api | local | account), sends (where data goes), configured, model.
    QVariantList providers() const;
    QString provider() const;
    void setProvider(const QString &id);
    bool busy() const { return !m_running.isEmpty(); }

    Q_INVOKABLE QString model(const QString &provider) const;
    Q_INVOKABLE void setModel(const QString &provider, const QString &model);
    Q_INVOKABLE bool setApiKey(const QString &provider, const QString &key);
    Q_INVOKABLE bool hasApiKey(const QString &provider) const;
    Q_INVOKABLE bool clearApiKey(const QString &provider);
    // Where keys are kept on this system, for Settings.
    Q_INVOKABLE QString keyStorage() const;
    Q_INVOKABLE bool consented(const QString &provider) const;
    Q_INVOKABLE void giveConsent(const QString &provider);
    // spec: provider, action (ask|translate), question, source, page (0-based), scope (selection|page|
    // paper|library|none), selection, quote, noteIds, imageFiles and imageLabels (what each image is, for
    // images from a paper). Returns a request id.
    // threadId continues a conversation (earlier turns are sent along); empty starts a new thread.
    Q_INVOKABLE int ask(const QVariantMap &spec);
    // Gloss: a word or phrase explained as used here, or a passage translated, into the reader's language;
    // quick (a fast model, little reasoning) and kept nowhere. spec: source, page (0-based), text. Only the
    // text and the sentences around it are sent. Streams delta(request, text) and ends with
    // finished(request, text, {model}) or failed.
    Q_INVOKABLE int gloss(const QVariantMap &spec);
    // What Gloss uses with a provider (Settings → AI, or the Gloss popup): a model, or "auto" for a fast one
    // (Claude Haiku; elsewhere the chat model), and a reasoning effort (default low).
    Q_INVOKABLE QString glossModel(const QString &provider) const;
    Q_INVOKABLE QString glossChoice(const QString &provider) const;
    Q_INVOKABLE QString glossEffort(const QString &provider) const;
    Q_INVOKABLE void setGloss(const QString &provider, const QString &model, const QString &effort);
    // The paper's symbols, asked for on request (Document panel › Symbols) and kept per paper and answer
    // language. Ends with notationChanged(source) and finished(request, "", {symbols}), or failed.
    Q_INVOKABLE int findSymbols(const QUrl &source);
    // That list: [{symbol (LaTeX), text (as printed), match (plain forms), meaning, page (1-based, 0:
    // background knowledge), quote (the defining words on that page)}], or [] before it is made.
    Q_INVOKABLE QVariantList notation(const QUrl &source);
    // Models the provider offers: Claude's current lineup, the OpenAI/Ollama/Codex lists from the service.
    Q_INVOKABLE void listModels(const QString &provider);
    Q_INVOKABLE void cancel(int request);
    Q_INVOKABLE void testConnection(const QString &provider);
    // Suggest named groups for open tabs. tabs: [{id, title, url, kind, authors, year, opening}].
    // Answered by tabsOrganized(request, groups [{name, tabIds}], error). Nothing is changed here.
    Q_INVOKABLE int organizeTabs(const QVariantList &tabs);
    // Suggest topic collections for papers. papers: [{id, title, authors, year, opening}]; collections:
    // names already in use, which the answer may reuse. Answered by papersOrganized(request,
    // groups [{name, paperIds}], error). Nothing is changed here.
    Q_INVOKABLE int organizePapers(const QVariantList &papers, const QStringList &collections);
    // A comparison table of papers. papers: [{title, authors, year, opening, closing}] (the start and the
    // conclusion of each); aspects: the table's columns. Streams comparisonDelta(request, text) and ends
    // with papersCompared(request, markdown, error).
    Q_INVOKABLE int comparePapers(const QVariantList &papers, const QStringList &aspects);
    // Codex app server: account status, ChatGPT sign-in (opens the browser) and sign-out.
    Q_INVOKABLE void refreshCodexAccount();
    Q_INVOKABLE void codexSignIn();
    Q_INVOKABLE void codexSignOut();
    // A pasted screenshot: saved under the data folder and returned as a file URL (empty if none).
    bool clipboardHasImage() const;
    Q_INVOKABLE QString saveClipboardImage();
    // A region of a PDF page (page-relative), drawn sharp enough to read and saved like a pasted image:
    // a figure attached from its preview. Returns a file URL, or empty.
    Q_INVOKABLE QString saveRegionImage(const QUrl &source, int page, const QRectF &region);

signals:
    void providersChanged();
    void busyChanged();
    void started(int request, const QString &threadId, const QString &provider, const QString &model, bool truncated);
    void delta(int request, const QString &text);
    // Summarized reasoning while the answer is prepared (kept with the answer, never resent).
    void thinking(int request, const QString &text);
    void finished(int request, const QString &text, const QVariantMap &details);
    void failed(int request, const QString &error);
    void connectionTested(const QString &provider, bool ok, const QString &detail);
    void tabsOrganized(int request, const QVariantList &groups, const QString &error);
    void papersOrganized(int request, const QVariantList &groups, const QString &error);
    void comparisonDelta(int request, const QString &text);
    void papersCompared(int request, const QString &markdown, const QString &error);
    void codexAccountChanged(const QVariantMap &account);
    // models: [{id, name}]
    void modelsLoaded(const QString &provider, const QVariantList &models);
    void notationChanged(const QUrl &source);

private:
    QString keyAccount(const QString &provider) const;
    QUrl baseUrl(const QString &provider) const;
    AiProvider *createProvider(const QString &provider, QString *error);
    QString attachmentDirectory() const;
    void run(int request, const QString &provider, const QVariantMap &spec, const QVariantMap &prepared);
    // <data>/ai-symbols/<paper and language>.json
    QString symbolsFile(const QUrl &source) const;
    void finishSymbols(int request, const QVariantMap &spec, const QString &answer, const QString &provider,
        const QString &model, bool stopped);
    // "Ask your library": search terms from the question (one short request), then the matching passages.
    void retrieveLibrary(int request, const QString &provider, QVariantMap spec, QVariantMap prepared);
    // Shared by tab and paper organization: items are named <prefix>1…N in the prompt, and the
    // answer's groups list them under memberKey. reply(request, groups [{name, ids}], error).
    using GroupReply = void (AiService::*)(int, const QVariantList &, const QString &);
    int suggestGroups(const QVariantList &items, const QString &prefix, const QString &memberKey, const QString &idsKey,
        const QString &system, const QString &text, GroupReply reply);
    ResearchStore *m_store;
    QNetworkAccessManager *m_network;
    CodexBridge *m_codex;
    QHash<int, QPointer<AiProvider>> m_running;
    int m_nextRequest = 0;
    QVariantMap m_codexAccount;
};
