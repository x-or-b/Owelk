#pragma once

#include <QObject>
#include <QStringList>
#include <QVariantList>

class QLocalServer;

// Files to open from outside: Finder (Open With, double-click: QFileOpenEvent) and a second launch
// with file arguments, which hands them to the Owelk already running for the same data folder and
// exits. Files that arrive before the window is ready wait in takePending().
class AppInstance final : public QObject {
    Q_OBJECT
public:
    explicit AppInstance(const QString &dataDirectory, QObject *parent = nullptr);
    // True when a running Owelk took the files (or was asked to come forward when there are none).
    bool forward(const QStringList &paths, int timeoutMs = 1500);
    // The last forward() reached a running Owelk that did not answer in time (still starting, or stuck): this launch
    // must not start a second Owelk on the same data.
    bool busy() const { return m_busy; }
    // Starts answering later launches; false when another Owelk holds the name (it is never taken from it).
    bool listen();
    // Files that arrived before the window asked; afterwards they come through filesRequested.
    Q_INVOKABLE QVariantList takePending();
    QString serverName() const { return m_name; }
    // Takes Finder's file-open events for PDFs (installed on the application).
    bool eventFilter(QObject *watched, QEvent *event) override;

signals:
    // urls of PDFs to open; empty when another launch only asked this window to come forward.
    void filesRequested(const QVariantList &urls);

private:
    void deliver(const QVariantList &urls);
    QString m_name;
    QLocalServer *m_server = nullptr;
    QVariantList m_pending;
    bool m_delivering = false;
    bool m_busy = false;
};
