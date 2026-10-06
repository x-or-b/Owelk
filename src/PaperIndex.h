#pragma once

#include <QObject>
#include <QSqlDatabase>
#include <QThreadPool>
#include <QUrl>
#include <QVariantList>
#include <QQueue>
#include <QSet>
#include <atomic>
#include <functional>
#include <memory>

// Rebuildable local search data. PDF parsing and search use separate worker-owned connections.
class PaperIndex final : public QObject {
    Q_OBJECT
public:
    // OCR with the installed Tesseract for pages without text; off when program is empty.
    struct Ocr {
        QString program, languages;
        bool enabled() const { return !program.isEmpty(); }
    };

private:
    Q_PROPERTY(QVariantList documents READ documents NOTIFY changed)
    Q_PROPERTY(QString progress READ progress NOTIFY changed)
    Q_PROPERTY(bool paused READ paused NOTIFY changed)
    Q_PROPERTY(bool busy READ busy NOTIFY changed)
public:
    explicit PaperIndex(const QString &directory, QObject *parent = nullptr);
    ~PaperIndex() override;
    bool initialize(QString *error);
    void enqueue(const QUrl &source);
    // Called on the UI thread when a file is indexed; returns the library's ID for it so both
    // databases name a paper the same way. Without one the index assigns its own IDs.
    void setDocumentResolver(std::function<QString(const QUrl &)> resolver) { m_resolver = std::move(resolver); }
    QVariantList documents() const;
    QString progress() const { return m_progress; }
    bool paused() const { return m_paused; }
    bool busy() const { return m_active || !m_queue.isEmpty() || m_relocating > 0; }
    QString knownHash(const QUrl &source) const;
    void relocateSource(const QUrl &source, const QUrl &candidate);
    Q_INVOKABLE void setPaused(bool paused);
    Q_INVOKABLE void retry(const QUrl &source);
    void setOcr(const Ocr &ocr);
    Ocr ocr() const { return m_ocr; }
    Q_INVOKABLE int search(const QString &text);
    // scopeIds: optional list of document IDs (from library filters); null searches everything.
    Q_INVOKABLE int searchGrouped(
        const QString &text, const QUrl &source, int offset, const QVariant &scopeIds = QVariant());
    void remove(const QUrl &source);
    // Excluded documents are never queued for indexing.
    void setExclusionCheck(std::function<bool(const QUrl &)> excluded) { m_excluded = std::move(excluded); }
    Q_INVOKABLE void openResult(const QString &documentId, int page, const QString &hash);
    // Papers sharing this one's distinctive words (keyword fallback when meaning search is off).
    // Answered by searchFinished: paper rows, then one {kind: "terms", terms} row.
    Q_INVOKABLE int related(const QString &documentId, int limit = 5);
    // The start of an indexed paper's text (its abstract, usually); empty when not indexed.
    QString openingText(const QString &documentId, int characters) const;
    Q_INVOKABLE void setReaderInteracting(QObject *reader, bool active);
    // Shared with other background work that must also yield to the reader.
    std::shared_ptr<std::atomic_bool> readerBusyFlag() const { return m_readerBusy; }
    QString databasePath() const { return m_path; }
    // From the last "Conclusion(s)" heading, before the references; empty when there is none.
    QString closingText(const QString &documentId, int characters) const;
signals:
    void changed();
    void contentsChanged();
    void searchFinished(int request, const QVariantList &results, const QString &error);
    void resultReady(const QUrl &source, int page);
    void message(const QString &text);

private:
    void startNext();
    QUrl resolvedSource(const QUrl &source) const;
    QString m_path, m_connection, m_progress;
    QSqlDatabase m_database;
    QThreadPool m_indexWorkers, m_searchWorkers;
    QQueue<QUrl> m_queue;
    QSet<QString> m_scheduled;
    QHash<QString, QString> m_redirects;
    int m_relocating = 0;
    std::function<QString(const QUrl &)> m_resolver;
    std::function<bool(const QUrl &)> m_excluded;
    QSet<QObject *> m_readers, m_interactingReaders;
    bool m_active = false, m_paused = false;
    Ocr m_ocr;
    int m_request = 0;
    std::shared_ptr<std::atomic_bool> m_cancel = std::make_shared<std::atomic_bool>(false);
    std::shared_ptr<std::atomic_bool> m_readerBusy = std::make_shared<std::atomic_bool>(false);
};
