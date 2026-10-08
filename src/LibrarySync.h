#pragma once

#include <QObject>
#include <QSet>
#include <QStringList>
#include <QThreadPool>
#include <QTimer>
#include <QUrl>
#include <atomic>
#include <memory>

// Keeps libraries on several computers the same through a folder that another program keeps in
// step (Google Drive, Dropbox, Syncthing, a network share). See docs/SYNC.md.
//
// Each computer writes only its own change files (devices/<id>/*.jsonl) and reads the others'. A
// change carries a whole row and its time; per row, the newest change wins and deletions travel as
// rows without contents. PDFs and images go to Papers/ and Files/ in the folder and are copied into
// this computer's data folder when they arrive. SQLite triggers note which rows changed, so the
// rest of the store does not know about syncing.
class LibrarySync final : public QObject {
    Q_OBJECT
    Q_PROPERTY(QString folder READ folder NOTIFY changed)
    Q_PROPERTY(bool running READ running NOTIFY changed)
    Q_PROPERTY(QString status READ status NOTIFY changed)
    Q_PROPERTY(QStringList computers READ computers NOTIFY changed)

public:
    struct Outcome {
        QString error;
        int received = 0, sent = 0, waiting = 0;
        QSet<QString> tables;
        QStringList newSources;
        QStringList computers;
    };
    LibrarySync(const QString &dataDirectory, QObject *parent = nullptr);
    ~LibrarySync() override;
    // Reads the saved folder and starts syncing in the background when there is one.
    void start();
    QString folder() const { return m_folder; }
    bool running() const { return m_running; }
    QString status() const { return m_status; }
    QStringList computers() const { return m_computers; }
    // Starts syncing with a folder; returns an error to show, or empty. Owelk's files go to an "Owelk"
    // folder inside it (unless it is that folder), so the drive's top folder works on every computer.
    Q_INVOKABLE QString setFolder(const QUrl &folder);
    Q_INVOKABLE void turnOff();
    Q_INVOKABLE void syncNow();
    // One whole pass on the calling thread (tests).
    Outcome syncBlocking();
    // At quit: stop copying files and write the last changes (files follow on the next start).
    void finish();

signals:
    void changed();
    // Rows from other computers arrived; newSources are PDFs now present here.
    void received(const QSet<QString> &tables, const QStringList &newSources);

private:
    void finished(const Outcome &outcome);
    QString m_directory, m_folder, m_device, m_library, m_status;
    QStringList m_computers;
    bool m_running = false, m_again = false;
    QThreadPool m_pool;
    QTimer m_timer;
    std::shared_ptr<std::atomic_bool> m_cancel = std::make_shared<std::atomic_bool>(false);
};
