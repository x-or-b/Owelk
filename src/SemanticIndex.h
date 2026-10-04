#pragma once

#include <QHash>
#include <QObject>
#include <QThreadPool>
#include <QTimer>
#include <QUrl>
#include <QVariantList>
#include <atomic>
#include <functional>
#include <memory>
#include <mutex>

class QNetworkAccessManager;
class PaperIndex;
class ResearchStore;

// Optional search by meaning, next to the keyword index. Off by default; when the reader turns it on,
// passages of indexed papers (the text PaperIndex already extracted), notes, annotations, captures and
// AI answers are embedded by an external engine (Ollama on this computer, or OpenAI) in the background,
// paused while reading. Vectors are int8 in semantic.sqlite3; nothing is opened while it is off.
class SemanticIndex final : public QObject {
    Q_OBJECT
    Q_PROPERTY(QString engine READ engine NOTIFY changed)
    Q_PROPERTY(QString model READ model NOTIFY changed)
    Q_PROPERTY(bool enabled READ enabled NOTIFY changed)
    Q_PROPERTY(bool busy READ busy NOTIFY changed)
    Q_PROPERTY(QString progress READ progress NOTIFY changed)
    Q_PROPERTY(QString error READ error NOTIFY changed)
public:
    SemanticIndex(ResearchStore *store, PaperIndex *index, QString directory, QObject *parent = nullptr);
    ~SemanticIndex() override;
    QString engine() const;
    QString model() const;
    bool enabled() const { return !engine().isEmpty(); }
    bool busy() const { return m_syncing; }
    QString progress() const { return m_progress; }
    QString error() const { return m_error; }
    static QString defaultModel(const QString &engine);
    // engine: "" (off), "ollama" or "openai". Changing the model rebuilds the vectors.
    Q_INVOKABLE void configure(const QString &engine, const QString &model);
    // Bring the vectors up to date soon (debounced); does nothing while off.
    Q_INVOKABLE void sync();
    // Delete all stored vectors (frees the disk space; turning it on again rebuilds them).
    Q_INVOKABLE void clear();
    // Results arrive in found(request, rows, error): rows like keyword search rows, with "semantic": true.
    Q_INVOKABLE int search(const QString &text, int limit = 12);
    // Papers whose content is closest to this one (mean of their passages); also answered by found().
    Q_INVOKABLE int relatedPapers(const QUrl &source, int limit = 5);
    // For tests and the settings page: stored passages.
    Q_INVOKABLE int storedCount() const;

    struct Matrix;
    struct Pending {
        QString kind, ref, document, hash, text;
        int page = 0, ord = 0;
    };

signals:
    void changed();
    void found(int request, const QVariantList &rows, const QString &error);

private:
    void runSync();
    void embedNext();
    void embed(const QStringList &texts, std::function<void(const QList<QList<float>> &, const QString &)> done);
    void finishSync(const QString &error);
    std::shared_ptr<const Matrix> matrix();
    void dropMatrix();
    ResearchStore *m_store;
    PaperIndex *m_index;
    QString m_directory, m_path;
    QNetworkAccessManager *m_network = nullptr;
    QThreadPool m_pool;
    QTimer m_syncTimer, m_releaseTimer;
    QList<Pending> m_pending;
    int m_done = 0, m_total = 0, m_request = 0;
    bool m_syncing = false, m_again = false;
    QString m_progress, m_error;
    std::mutex m_matrixLock;
    std::shared_ptr<const Matrix> m_matrix;
    std::shared_ptr<std::atomic_bool> m_cancel = std::make_shared<std::atomic_bool>(false);
};
