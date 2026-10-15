#include "AppInstance.h"

#include <QCryptographicHash>
#include <QDir>
#include <QFileInfo>
#include <QFileOpenEvent>
#include <QLocalServer>
#include <QLocalSocket>
#include <QUrl>

AppInstance::AppInstance(const QString &dataDirectory, QObject *parent) : QObject(parent)
{
    // One running Owelk per data folder (and user); short, as local socket paths are limited.
    const auto key = QDir(dataDirectory).absolutePath().toUtf8() + qgetenv("USER") + qgetenv("USERNAME");
    m_name = "owelk-" + QCryptographicHash::hash(key, QCryptographicHash::Sha1).toHex().left(16);
#ifdef Q_OS_LINUX
    // In the user's own runtime folder, not the /tmp every user shares (where another account could take the name).
    if (const auto runtime = qEnvironmentVariable("XDG_RUNTIME_DIR"); !runtime.isEmpty() && QFileInfo(runtime).isDir())
        m_name = runtime + "/" + m_name;
#endif
}

bool AppInstance::forward(const QStringList &paths, int timeoutMs)
{
    m_busy = false;
    QLocalSocket socket;
    socket.connectToServer(m_name);
    if (!socket.waitForConnected(timeoutMs)) return false;
    // Someone is there from here on: no answer means it is busy, not gone.
    m_busy = true;
    QByteArray message;
    for (const auto &path : paths) message += QFileInfo(path).absoluteFilePath().toUtf8() + '\n';
    message += "\n"; // An empty line ends the request.
    socket.write(message);
    if (!socket.waitForBytesWritten(timeoutMs)) return false;
    // The answer says the files were taken.
    const bool taken = socket.waitForReadyRead(timeoutMs) && socket.readAll().startsWith("ok");
    if (taken) m_busy = false;
    return taken;
}

bool AppInstance::listen()
{
    // Never taken from an Owelk that runs with it (listening puts a new socket in its place, so the running one
    // would no longer hear later launches): only a name nothing answers on, left over from a crash.
    QLocalSocket probe;
    probe.connectToServer(m_name);
    if (probe.waitForConnected(300)) return false;
    QLocalServer::removeServer(m_name);
    m_server = new QLocalServer(this);
    m_server->setSocketOptions(QLocalServer::UserAccessOption);
    if (!m_server->listen(m_name)) return false;
    connect(m_server, &QLocalServer::newConnection, this, [this] {
        while (auto *socket = m_server->nextPendingConnection()) {
            connect(socket, &QLocalSocket::disconnected, socket, &QObject::deleteLater);
            connect(socket, &QLocalSocket::readyRead, socket, [this, socket] {
                const auto data = socket->peek(socket->bytesAvailable());
                if (!data.endsWith("\n\n") && data != "\n") return;
                QVariantList urls;
                for (const auto &line : socket->readAll().split('\n'))
                    if (!line.isEmpty()) urls.append(QUrl::fromLocalFile(QString::fromUtf8(line)));
                socket->write("ok\n");
                socket->flush();
                deliver(urls);
            });
        }
    });
    return true;
}

QVariantList AppInstance::takePending()
{
    m_delivering = true;
    const auto pending = m_pending;
    m_pending.clear();
    return pending;
}

void AppInstance::deliver(const QVariantList &urls)
{
    if (m_delivering)
        emit filesRequested(urls);
    else
        m_pending.append(urls);
}

bool AppInstance::eventFilter(QObject *watched, QEvent *event)
{
    if (event->type() == QEvent::FileOpen) {
        const auto *open = static_cast<QFileOpenEvent *>(event);
        const auto url = open->url().isLocalFile() ? open->url() : QUrl::fromLocalFile(open->file());
        if (url.toLocalFile().endsWith(".pdf", Qt::CaseInsensitive)) {
            deliver({url});
            return true;
        }
    }
    return QObject::eventFilter(watched, event);
}
