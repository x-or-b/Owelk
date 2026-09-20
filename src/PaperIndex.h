#pragma once

#include <QObject>
#include <QSqlDatabase>
#include <QThreadPool>
#include <QUrl>
#include <QVariantList>
#include <QQueue>
#include <QSet>
#include <atomic>
#include <memory>

// Rebuildable local search data. PDF parsing and search use separate worker-owned connections.
class PaperIndex final : public QObject
{
    Q_OBJECT
    Q_PROPERTY(QVariantList documents READ documents NOTIFY changed)
    Q_PROPERTY(QString progress READ progress NOTIFY changed)
    Q_PROPERTY(bool paused READ paused NOTIFY changed)
    Q_PROPERTY(bool busy READ busy NOTIFY changed)
public:
    explicit PaperIndex(const QString &directory, QObject *parent = nullptr);
    ~PaperIndex() override;
    bool initialize(QString *error);
    void enqueue(const QUrl &source);
    QVariantList documents() const;
    QString progress() const { return m_progress; }
    bool paused() const { return m_paused; }
    bool busy() const { return m_active || !m_queue.isEmpty(); }
    Q_INVOKABLE void setPaused(bool paused);
    Q_INVOKABLE void retry(const QUrl &source);
    Q_INVOKABLE int search(const QString &text);
    Q_INVOKABLE void openResult(const QString &documentId, int page, const QString &hash);
    Q_INVOKABLE void setReaderInteracting(QObject *reader, bool active);
signals:
    void changed();
    void contentsChanged();
    void searchFinished(int request, const QVariantList &results, const QString &error);
    void resultReady(const QUrl &source, int page);
    void message(const QString &text);
private:
    void startNext();
    QString m_path, m_connection, m_progress;
    QSqlDatabase m_database;
    QThreadPool m_indexWorkers, m_searchWorkers;
    QQueue<QUrl> m_queue;
    QSet<QString> m_scheduled;
    QSet<QObject *> m_readers, m_interactingReaders;
    bool m_active = false, m_paused = false;
    int m_request = 0;
    std::shared_ptr<std::atomic_bool> m_cancel = std::make_shared<std::atomic_bool>(false);
    std::shared_ptr<std::atomic_bool> m_readerBusy = std::make_shared<std::atomic_bool>(false);
};
