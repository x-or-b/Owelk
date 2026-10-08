#pragma once

#include <QObject>
#include <QHash>
#include <QImage>
#include <QRectF>
#include <QSet>
#include <QStringList>
#include <QSqlDatabase>
#include <QThreadPool>
#include <QUrl>
#include <QVariantList>
#include <QVariantMap>

class LibrarySync;
class PaperIndex;
class ReferenceFinder;
class QNetworkAccessManager;
class QPdfDocument;

class ResearchStore final : public QObject {
    Q_OBJECT
    Q_PROPERTY(QVariantMap session READ session NOTIFY homeChanged)
    Q_PROPERTY(QVariantList captures READ captures NOTIFY capturesChanged)
    Q_PROPERTY(QVariantList trashedCaptures READ trashedCaptures NOTIFY capturesChanged)
    Q_PROPERTY(QVariantList recentDocuments READ recentDocuments NOTIFY recentDocumentsChanged)
    Q_PROPERTY(bool busy READ busy NOTIFY busyChanged)
    Q_PROPERTY(bool printing READ printing NOTIFY printingChanged)
    // Bumps when undo/redo history changes (for enabling Undo and Redo).
    Q_PROPERTY(int historyRevision READ historyRevision NOTIFY historyChanged)
    Q_PROPERTY(QString dataDirectory READ dataDirectory CONSTANT)
    Q_PROPERTY(QVariantList recentWorkspaces READ recentWorkspaces NOTIFY homeChanged)
    Q_PROPERTY(QVariantMap continueReading READ continueReading NOTIFY homeChanged)
    Q_PROPERTY(QObject *paperIndex READ paperIndex CONSTANT)
    // Where "[12]", "Fig. 3" and the like point, for papers without working links (ReferenceFinder).
    Q_PROPERTY(QObject *references READ references CONSTANT)
    // Online details lookup, used only from the Paper Details dialog's button.
    Q_PROPERTY(QObject *metadataLookup READ metadataLookup CONSTANT)
    Q_PROPERTY(QObject *ai READ ai CONSTANT)
    Q_PROPERTY(QObject *semantic READ semantic CONSTANT)
    // Keeping this library the same on other computers through a shared folder (LibrarySync.h).
    Q_PROPERTY(QObject *sync READ sync CONSTANT)
    Q_PROPERTY(bool backingUp READ backingUp NOTIFY backingUpChanged)
    Q_PROPERTY(bool recoveredFromCrash READ recoveredFromCrash CONSTANT)
    Q_PROPERTY(QString startupMessage READ startupMessage CONSTANT)
    Q_PROPERTY(bool relinking READ relinking NOTIFY relinkingChanged)
    // Copying the Library's outside PDFs into papers/ (ResearchStorePapers.cpp).
    Q_PROPERTY(bool copyingPdfs READ copyingPdfs NOTIFY copyingPdfsChanged)
    Q_PROPERTY(QStringList annotationColors READ annotationColors CONSTANT)
    // Bumped when paper titles or details change; bind to it next to displayName() calls.
    Q_PROPERTY(int documentsRevision READ documentsRevision NOTIFY documentsChanged)

public:
    explicit ResearchStore(const QString &directory, QObject *parent = nullptr);
    ~ResearchStore() override;
    bool initialize(QString *error);
    // The only accepted annotation inks; Theme.annotationInks (src/ui/Theme.cpp) must list the same values.
    static QStringList annotationColors();
    static QString defaultAnnotationColor() { return annotationColors().constFirst(); }
    // "Figure 3: …" / "Table 2 …" next to a captured region (normalised page coordinates), or empty.
    static QString figureCaption(QPdfDocument &document, int page, const QRectF &region);
    QVariantMap session() const;
    QVariantList captures() const { return m_captures; }
    QVariantList trashedCaptures() const { return m_trashedCaptures; }
    QVariantList recentDocuments() const;
    bool busy() const { return m_pending > 0; }
    bool printing() const { return m_printing; }
    QString dataDirectory() const { return m_directory; }
    QObject *paperIndex() const;
    QObject *references() const;
    QObject *metadataLookup() const { return m_lookup; }
    QObject *ai() const { return m_ai; }
    QObject *semantic() const;
    QObject *sync() const;
    LibrarySync *librarySync() const { return m_sync; }
    bool relinking() const { return m_relinking; }
    bool copyingPdfs() const { return m_copyingPdfs; }
    // "Keep PDFs in Owelk" (setting library.keepPdfs, on by default): PDFs that are opened, added or
    // downloaded are copied into the data folder's papers/; originals stay untouched.
    bool keepsPdfs() const;
    QString papersFolder() const;
    Q_INVOKABLE QUrl papersFolderUrl() const;
    // The URL to open for a PDF: the Library's own copy (made now if needed) while PDFs are kept.
    Q_INVOKABLE QUrl adoptPdf(const QUrl &source);
    // Library papers whose file is still outside papers/, and copying them in (one by one, each
    // only after its copy matched byte for byte, like Locate Original PDF).
    Q_INVOKABLE int outsidePdfCount() const;
    Q_INVOKABLE void copyPdfsIntoLibrary();
    Q_INVOKABLE QUrl resolvedSource(const QUrl &source) const;
    Q_INVOKABLE void requestRelink(const QUrl &source);
    Q_INVOKABLE void relinkSource(const QUrl &source, const QUrl &candidate);

    Q_INVOKABLE bool saveSession(const QVariantMap &state);
    Q_INVOKABLE bool rememberDocument(const QUrl &url);
    Q_INVOKABLE bool removeRecentDocument(const QUrl &url);
    Q_INVOKABLE bool deleteCapture(const QString &id);
    Q_INVOKABLE bool restoreCapture(const QString &id);
    // Permanent removal from the local trash only; saved captures and original PDFs are never touched.
    Q_INVOKABLE bool purgeCapture(const QString &id);
    Q_INVOKABLE int emptyCaptureTrash();
    Q_INVOKABLE bool saveCaptureNote(const QString &id, const QString &body);
    Q_INVOKABLE QString fileName(const QUrl &url) const;
    // A local file URL as a path in the platform's own form (C:\Users\… on Windows), or the URL text.
    Q_INVOKABLE QString localPath(const QUrl &url) const;
    // A path (any platform form) as a file URL.
    Q_INVOKABLE QUrl fileUrl(const QString &path) const;
    // Paper title when known, otherwise the file name.
    Q_INVOKABLE QString displayName(const QUrl &source) const;
    Q_INVOKABLE QVariantMap documentDetails(const QUrl &source) const;
    Q_INVOKABLE bool updateDocumentDetails(const QUrl &source, const QVariantMap &details);
    // Forget edits and read the details from the PDF again.
    Q_INVOKABLE void resetDocumentDetails(const QUrl &source);
    // unread | reading | read. Opening a paper moves it from unread to reading.
    Q_INVOKABLE bool setReadingState(const QUrl &source, const QString &state);
    Q_INVOKABLE bool setFavorite(const QUrl &source, bool favorite);
    // Stop offering the existing copy for this exact file version.
    Q_INVOKABLE bool keepDuplicate(const QUrl &source);
    // Read the existing copy instead: the duplicate leaves Recent Papers, the existing copy is reopened.
    Q_INVOKABLE bool useExistingCopy(const QUrl &duplicate, const QUrl &existing);

    // Library organisation (ResearchStoreLibrary.cpp). Filters: see libraryDocuments().
    Q_INVOKABLE QVariantList libraryDocuments(const QVariantMap &filter = {}) const;
    Q_INVOKABLE QStringList documentIdsInScope(const QVariantMap &filter) const;
    Q_INVOKABLE QVariantList collections() const;
    // Papers in no collection (the Library's Unsorted view).
    Q_INVOKABLE int unsortedCount() const;
    // Modifier keys of the current input event (list rows: Cmd/Ctrl-click and Shift-click select).
    Q_INVOKABLE int keyboardModifiers() const;
    // Adds (or removes) several papers at once.
    Q_INVOKABLE bool setDocumentsCollection(const QVariantList &sources, const QString &collectionId, bool member);
    // Adds PDFs to the Library (and to a collection, if given) without opening them; their details and
    // text are read in the background. Returns how many were added.
    Q_INVOKABLE int addDocuments(const QVariantList &sources, const QString &collectionId = QString());
    // Takes papers out of the Library: lists, recent papers, collections, tags and the text index.
    // The PDF file, annotations and captures stay; opening the file again brings the paper back.
    Q_INVOKABLE int removeFromLibrary(const QVariantList &sources);
    // Adds every PDF under a folder (subfolders included; hidden files and links skipped), found in
    // the background. With foldersAsCollections, the folder and its subfolders become a collection
    // tree (existing ones with the same name are reused) under parentCollection. Files are not moved.
    // Answered by folderImported(request, added, collections, error).
    Q_INVOKABLE int importFolder(const QUrl &folder, const QString &parentCollection, bool foldersAsCollections);
    // Moves the PDF files to the system Trash (recoverable there) and removes the papers from the Library.
    Q_INVOKABLE int movePdfsToTrash(const QVariantList &sources);
    // Collections where similar papers already are, for a paper in none of them (or to add more):
    // answered by collectionsSuggested(request, source, [{id, name}]). No AI; the related-papers
    // search, cached until the library changes.
    Q_INVOKABLE int suggestCollections(const QUrl &source);
    Q_INVOKABLE QString createCollection(const QString &name, const QString &parentId = QString());
    Q_INVOKABLE bool renameCollection(const QString &id, const QString &name);
    Q_INVOKABLE bool deleteCollection(const QString &id);
    Q_INVOKABLE bool setDocumentCollection(const QUrl &source, const QString &collectionId, bool member);
    Q_INVOKABLE QVariantList tags() const;
    Q_INVOKABLE bool setDocumentTags(const QUrl &source, const QStringList &names);
    Q_INVOKABLE QVariantMap documentOrganization(const QUrl &source) const;
    Q_INVOKABLE bool setExcludedFromIndex(const QUrl &source, bool excluded);
    Q_INVOKABLE bool excludedFromIndex(const QUrl &source) const;

    // Standalone Markdown notes and links between knowledge objects (ResearchStoreNotes.cpp).
    // Link kinds: note, capture, highlight, document, ai. Note bodies link with owelk://<kind>/<id>.
    Q_INVOKABLE QString createNote(const QString &title = QString(), const QString &body = QString());
    Q_INVOKABLE QVariantMap note(const QString &id) const;
    Q_INVOKABLE bool saveNote(const QString &id, const QString &title, const QString &body);
    Q_INVOKABLE QVariantList notes(bool trashed = false) const;
    Q_INVOKABLE bool deleteNote(const QString &id);
    Q_INVOKABLE bool restoreNote(const QString &id);
    Q_INVOKABLE bool purgeNote(const QString &id);
    Q_INVOKABLE bool addLink(
        const QString &fromKind, const QString &fromId, const QString &toKind, const QString &toId);
    Q_INVOKABLE QVariantMap linkTarget(const QString &kind, const QString &id) const;
    Q_INVOKABLE QVariantList backlinks(const QString &kind, const QString &id) const;
    // Papers and notes related to a paper, computed on request: meaning vectors when meaning search
    // is on, otherwise the paper's distinctive words. Answered by relatedFound(request, papers, notes).
    Q_INVOKABLE int relatedTo(const QUrl &source);
    // The opening of a paper's indexed text (for tab organization); empty when not indexed yet.
    Q_INVOKABLE QString paperOpening(const QUrl &source, int characters = 400);
    // From the paper's text index: its start (abstract, introduction) and its conclusion.
    // Papers this one cites and papers citing it, from Semantic Scholar (only when asked; a month's cache).
    // Answered by citationsLoaded(request, source, {references, citedBy, cached, error}); each row has
    // title, year, authors, doi, arxiv, citations, url and inLibrary (the file, when it is in the Library).
    // cachedOnly answers from the cache or with {notLoaded: true}, never touching the network.
    Q_INVOKABLE int loadCitations(const QUrl &source, bool refresh = false, bool cachedOnly = false);
    // Passages from the Library for a question: the best pages for the terms (at most two per paper),
    // each as {n, documentId, source, title, year, page (0-based), excerpt}.
    // With a collection, only its papers (and those of its sub-collections).
    QVariantList libraryPassages(const QStringList &terms, int limit, const QString &collection = QString());
    Q_INVOKABLE QVariantMap paperExcerpt(const QUrl &source, int opening = 5000, int closing = 2500);
    // Encrypted PDFs: the viewer hands over a password that worked, so indexing, captures, printing
    // and AI can open the file too. keep: also store it in the system keyring.
    Q_INVOKABLE void rememberPdfPassword(const QUrl &source, const QString &password, bool keep);
    Q_INVOKABLE QString pdfPassword(const QUrl &source) const;
    // OCR for scanned pages with the installed Tesseract: found, program, languages, installed, enabled.
    Q_INVOKABLE QVariantMap ocrStatus() const;
    Q_INVOKABLE void setOcr(bool enabled, const QString &languages);
    // Backups: a folder with the library database, captures and annotations (see ResearchStoreBackup.cpp).
    Q_INVOKABLE void backUp(const QString &folder);
    Q_INVOKABLE QString checkBackup(const QString &folder) const;
    // Exports (new files only): a paper's highlights, comments and captures as Markdown; every note as a
    // Markdown file; BibTeX for papers (sources: file URLs).
    Q_INVOKABLE QString exportPaperMarkdown(const QUrl &source, const QString &folder);
    Q_INVOKABLE int exportNotesMarkdown(const QString &folder);
    Q_INVOKABLE QString bibtex(const QVariantList &sources) const;
    Q_INVOKABLE bool exportBibTeX(const QVariantList &sources, const QString &file);
    Q_INVOKABLE bool scheduleRestore(const QString &folder);
    bool backingUp() const { return m_backingUp; }
    // Unsaved editor text, kept so a crash does not lose it.
    Q_INVOKABLE bool saveDraft(const QString &key, const QString &text);
    Q_INVOKABLE QString draft(const QString &key) const;
    Q_INVOKABLE void clearDraft(const QString &key);
    bool recoveredFromCrash() const { return m_recovered; }
    QString startupMessage() const { return m_startupMessage; }
    // Applies a restore staged by scheduleRestore; call before the database is opened.
    static bool applyPendingRestore(const QString &directory, QString *message);
    // Notes sharing the words of this note (local, immediate).
    Q_INVOKABLE QVariantList relatedNotes(const QString &noteId) const;
    Q_INVOKABLE QVariantList linkCandidates(const QString &query) const;
    Q_INVOKABLE QString documentLinkId(const QUrl &source);
    Q_INVOKABLE QString markdownHtml(const QString &markdown, const QString &linkColor) const;
    // "[title](owelk://kind/id)" for inserting into a note.
    Q_INVOKABLE QString markdownLink(const QString &kind, const QString &id) const;
    // AI conversations (ResearchStoreAi.cpp). A thread keeps its turns; message: role, content (sent),
    // display (typed), context, model, provider.
    Q_INVOKABLE QString createAiThread(const QVariantMap &thread);
    Q_INVOKABLE bool appendAiMessage(const QString &threadId, const QVariantMap &message);
    Q_INVOKABLE QVariantList aiThreads() const;
    Q_INVOKABLE QVariantMap aiThread(const QString &id) const;
    Q_INVOKABLE bool renameAiThread(const QString &id, const QString &title);
    Q_INVOKABLE bool deleteAiThread(const QString &id);
    // Saved AI answers. response: provider, model, action, question, answer, prompt, source, page, captureId.
    Q_INVOKABLE QString saveAiResponse(const QVariantMap &response);
    Q_INVOKABLE QVariantMap aiResponse(const QString &id) const;
    Q_INVOKABLE bool appendNoteLink(const QString &noteId, const QString &kind, const QString &id);
    int documentsRevision() const { return m_documentsRevision; }
    Q_INVOKABLE bool sameSource(const QUrl &first, const QUrl &second) const { return first == second; }
    Q_INVOKABLE void captureRegion(const QUrl &source, int page, const QRectF &normalizedRegion);
    // A region of a web page screenshot (normalised to the image); opening it reopens the page.
    Q_INVOKABLE void captureWebImage(const QUrl &page, const QString &title, const QImage &image, const QRectF &region);
    // segments: [{page, from, to, text}] in PDF points, one per page of a selection spanning pages.
    Q_INVOKABLE void captureTextSegments(const QUrl &source, const QVariantList &segments);
    Q_INVOKABLE void captureText(
        const QUrl &source, int page, const QPointF &from, const QPointF &to, const QString &expectedText);
    Q_INVOKABLE void highlightText(const QUrl &source, int page, const QPointF &from, const QPointF &to,
        const QString &expectedText, const QString &color = defaultAnnotationColor());
    Q_INVOKABLE void commentText(const QUrl &source, int page, const QPointF &from, const QPointF &to,
        const QString &expectedText, const QString &body, const QString &color = defaultAnnotationColor());
    Q_INVOKABLE bool updateHighlight(const QString &id, const QString &color, const QString &body);
    Q_INVOKABLE void saveAnnotation(const QUrl &source, int page, const QVariantMap &annotation);
    Q_INVOKABLE QUrl annotationPreviewUrl(const QUrl &source) const
    {
        return QUrl(QStringLiteral("image://annotation/")
            + QString::fromLatin1(
                source.toEncoded().toBase64(QByteArray::Base64UrlEncoding | QByteArray::OmitTrailingEquals)));
    }
    Q_INVOKABLE void printDocument(const QUrl &source, const QString &fingerprint, int pages);
    // Printing without dialogs, into a PDF file (tests).
    void printDocumentTo(const QUrl &source, const QString &fingerprint, int pages, const QString &pdfFile);
    // A copy of the PDF with Owelk's annotations as standard PDF annotations (needs qpdf in the build).
    Q_INVOKABLE void exportAnnotatedPdf(const QUrl &source, const QString &fingerprint, const QString &file);
    Q_INVOKABLE bool canExportAnnotatedPdf() const;
    Q_INVOKABLE int loadHighlights(const QUrl &source);
    Q_INVOKABLE bool removeHighlight(const QString &id);
    // Undo/redo the last annotation or capture change in this document (Cmd+Z, Cmd+Shift+Z).
    Q_INVOKABLE bool undo(const QUrl &source) { return replay(source, false); }
    Q_INVOKABLE bool redo(const QUrl &source) { return replay(source, true); }
    Q_INVOKABLE bool canUndo(const QUrl &source) const;
    Q_INVOKABLE bool canRedo(const QUrl &source) const;
    int historyRevision() const { return m_historyRevision; }
    // Where a capture or annotation sits (a DocumentAnchor; see ResearchStoreAnchors.cpp), and the one
    // way to show it: verify the source, then move the reader there.
    Q_INVOKABLE QVariantMap anchor(const QString &item, const QString &id) const;
    Q_INVOKABLE void revealAnchor(const QVariantMap &anchor);
    Q_INVOKABLE void openHighlight(const QString &id);
    Q_INVOKABLE void openCapture(const QString &id);
    Q_INVOKABLE void copyText(const QString &text);
    // Show a status message from QML through the same channel as store messages.
    Q_INVOKABLE void notify(const QString &text) { emit message(text); }
    Q_INVOKABLE int listFolder(const QUrl &folder);
    Q_INVOKABLE QVariantMap readingPosition(const QUrl &source) const;
    // Plain preferences in the settings table (download folder, search engine, AI language, …).
    Q_INVOKABLE QString setting(const QString &key, const QString &fallback = QString()) const;
    Q_INVOKABLE bool setSetting(const QString &key, const QString &value);
    // Where a web download should be saved: the chosen folder (default ~/Downloads) and a name that
    // never overwrites an existing file. Returns directory, fileName and url.
    // PDFs go to papers/ while PDFs are kept in Owelk.
    Q_INVOKABLE QVariantMap downloadTarget(const QString &suggestedName, bool pdf = false) const;
    // scopeUrls: optional list of paper URLs (library filters); null searches everything.
    Q_INVOKABLE QVariantList searchKnowledge(const QString &query, const QUrl &source = QUrl(),
        const QString &target = "all", const QVariant &scopeUrls = QVariant()) const;
    // Same results as searchKnowledge, computed off the UI thread; answered by knowledgeFound(request, rows).
    Q_INVOKABLE int searchKnowledgeAsync(const QString &query, const QUrl &source = QUrl(),
        const QString &target = "all", const QVariant &scopeUrls = QVariant());
    Q_INVOKABLE QString createWorkspace(const QString &name);
    Q_INVOKABLE QVariantMap loadWorkspace(const QString &id);
    Q_INVOKABLE bool saveWorkspace(const QString &id, const QVariantMap &state);
    Q_INVOKABLE QVariantMap workspaceDetails(const QString &id) const;
    Q_INVOKABLE bool setWorkspaceDocument(const QString &id, const QUrl &source, bool linked);
    Q_INVOKABLE bool setWorkspaceCapture(const QString &id, const QString &captureId, bool linked);
    Q_INVOKABLE bool renameWorkspace(const QString &id, const QString &name);
    Q_INVOKABLE bool deleteWorkspace(const QString &id);
    Q_INVOKABLE QVariantList deletedWorkspaces() const;
    Q_INVOKABLE bool restoreWorkspace(const QString &id);
    // Forgets a deleted workspace for good (its layout and links; papers, captures and notes stay).
    // An empty id forgets every deleted workspace. Returns how many were removed.
    Q_INVOKABLE int purgeDeletedWorkspaces(const QString &id = QString());
    QVariantList recentWorkspaces() const;
    QVariantMap continueReading() const;

signals:
    void highlightsChanged();
    void documentsChanged();
    void settingsChanged();
    void notesChanged();
    void linksChanged();
    void relatedFound(int request, const QVariantList &papers, const QVariantList &notes);
    void collectionsSuggested(int request, const QUrl &source, const QVariantList &suggestions);
    void folderImported(int request, int added, int collections, const QString &error);
    void citationsLoaded(int request, const QUrl &source, const QVariantMap &result);
    void ocrChanged();
    void backingUpChanged();
    void backupFinished(bool ok, const QString &path, const QString &message);
    void annotatedPdfExported(bool ok, const QString &file);
    void aiThreadsChanged();
    // The opened file has the same bytes as another library entry that still exists.
    void duplicateFound(const QUrl &source, const QUrl &existing, const QString &existingTitle);
    void highlightSaved(const QString &id, const QUrl &source);
    void highlightsLoaded(int request, const QUrl &source, const QVariantList &highlights, const QString &error,
        const QString &fingerprint);
    void annotationSaved(const QString &id);
    void annotationFinished(bool success, const QString &id);
    void capturesChanged();
    void recentDocumentsChanged();
    void busyChanged();
    void printingChanged();
    void historyChanged();
    void message(const QString &text);
    void captureSaved(const QString &id);
    void knowledgeFound(int request, const QVariantList &results);
    void sourceReady(const QUrl &source, int page, const QRectF &region);
    void webSourceRequested(const QUrl &page);
    void folderLoaded(int requestId, const QUrl &folder, const QVariantList &entries, const QString &error);
    void homeChanged();
    void workspaceRenamed(const QString &id, const QString &name);
    void workspaceDeleted(const QString &id);
    void relinkingChanged();
    void copyingPdfsChanged();
    void relinkRequested(const QUrl &source);
    void sourceRelinked(const QUrl &source, const QUrl &candidate);
    void relinkFinished(bool success, const QString &detail);

private:
    void saveTextSelection(const QUrl &source, int page, const QPointF &from, const QPointF &to,
        const QString &expectedText, bool asHighlight, const QString &color = defaultAnnotationColor(),
        const QString &kind = "highlight", const QString &body = QString());
    void reloadCaptures();
    int purgeTrashedCaptures(const QStringList &ids);
    // Saved data is keyed by document ID; QML keeps passing file URLs.
    QString findDocument(const QUrl &source) const;
    QString ensureDocument(const QUrl &source);
    QString ensureWebDocument(const QUrl &page, const QString &title);
    void loadDocumentNames();
    void syncNoteLinks(const QString &noteId, const QString &body);
    void rememberTitle(const QUrl &url, const QString &title);
    void refreshMetadata(const QString &id, const QUrl &url, bool force, bool checkDuplicate = false);
    void reportDuplicate(const QString &id, const QUrl &url, const QString &hash);
    void announceDocumentsChanged();
    static bool adoptDocumentIds(QSqlDatabase &db, QString *error);
    QVariantList readCaptures(bool trashed) const;
    QVariantMap canonicalState(const QVariantMap &state) const;
    bool applyRelink(const QUrl &source, const QUrl &candidate, const QString &hash, QString *error);
    QHash<QString, QString> m_relinks;
    bool m_relinking = false;
    bool m_copyingPdfs = false;
    static QStringList adoptPdfFiles(const QString &directory, const QString &papers,
        const QHash<QString, QString> &relinks, const QStringList &paths);
    // Same-bytes files met earlier in one batch reuse that copy.
    QUrl adoptPdf(const QUrl &source, QHash<QString, QUrl> *batch);
    static QString defaultPapersFolder(const QString &directory);
    void relocatePapers();
    QString m_papers;
    QString m_directory;
    QString m_connection;
    QSqlDatabase m_database;
    QVariantList m_captures;
    QVariantList m_trashedCaptures;
    // Writes (captures, annotations, relink, print) stay ordered on one thread.
    // Read-only source checks and folder listing use their own pool so a click never waits behind a save.
    QThreadPool m_workers;
    QThreadPool m_verifiers;
    QThreadPool m_metadataWorkers;
    QHash<QString, QString> m_titles;
    QSet<QString> m_metadataPending;
    QSet<QString> m_duplicateChecks;
    int m_documentsRevision = 0;
    bool m_documentsChangePending = false;
    int m_pending = 0;
    int m_folderRequest = 0;
    int m_highlightRequest = 0;
    int m_knowledgeRequest = 0;
    bool m_printing = false;
    // Undo and redo, per document, for this session: annotation states and capture trash moves.
    struct HistoryStep {
        QString type, id, label;
        QVariantMap before, after;
    };
    QHash<QString, QList<HistoryStep>> m_undo, m_redo;
    bool m_replaying = false;
    int m_historyRevision = 0;
    QVariantMap annotationState(const QString &id) const;
    bool applyAnnotationState(const QString &id, const QVariantMap &state);
    void recordAnnotation(const QString &id, const QVariantMap &before, const QString &label);
    void recordCapture(const QString &id, bool trashed);
    void pushHistory(const QString &document, const HistoryStep &step);
    bool replay(const QUrl &source, bool forward);
    int m_relatedRequest = 0;
    int m_suggestRequest = 0;
    int m_importRequest = 0;
    bool m_quietAdd = false;
    QHash<QString, QVariantList> m_suggestions;
    void configureOcr();
    void scheduleAutomaticBackup();
    void markRunning();
    void markStopped();
    bool m_backingUp = false, m_recovered = false;
    QString m_startupMessage;
    QString m_ocrProgram;
    QStringList m_ocrInstalled;
    QVariantList notesSharing(const QStringList &terms, const QString &exceptNote) const;
    bool readPrintMarks(const QUrl &source, const QString &hash, QVariantList *marks);
    PaperIndex *m_index;
    ReferenceFinder *m_references;
    QNetworkAccessManager *m_citationNetwork = nullptr;
    int m_citationRequest = 0;
    QVariantMap withLibraryMatches(QVariantMap result) const;
    QObject *m_lookup;
    QObject *m_ai;
    class SemanticIndex *m_semantic = nullptr;
    LibrarySync *m_sync;
    void syncReceived(const QSet<QString> &tables, const QStringList &sources);
};
