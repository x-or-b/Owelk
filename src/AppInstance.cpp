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
}

bool AppInstance::forward(const QStringList &paths, int timeoutMs)
{
    QLocalSocket socket;
    socket.connectToServer(m_name);
    if (!socket.waitForConnected(timeoutMs)) return false;
    QByteArray message;
    for (const auto &path : paths) message += QFileInfo(path).absoluteFilePath().toUtf8() + '\n';
    message += "\n"; // An empty line ends the request.
    socket.write(message);
    if (!socket.waitForBytesWritten(timeoutMs)) return false;
    // The answer says the files were taken.
    return socket.waitForReadyRead(timeoutMs) && socket.readAll().startsWith("ok");
}

bool AppInstance::listen()
{
    m_server = new QLocalServer(this);
    m_server->setSocketOptions(QLocalServer::UserAccessOption);
    if (!m_server->listen(m_name)) {
        // Left over from a crash: nobody answered forward(), so the name is free to take.
        QLocalServer::removeServer(m_name);
        if (!m_server->listen(m_name)) return false;
    }
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
