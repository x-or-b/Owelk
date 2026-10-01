#pragma once

#include <QSqlDatabase>
#include <QString>
#include <QUuid>

// A short-lived SQLite connection owned by one worker task. QSqlDatabase handles must not cross threads.
struct WorkerConnection {
    QString name = QUuid::createUuid().toString();
    QSqlDatabase db = QSqlDatabase::addDatabase("QSQLITE", name);
    explicit WorkerConnection(const QString &path, bool readOnly = false)
    {
        db.setDatabaseName(path);
        db.setConnectOptions(readOnly ? "QSQLITE_BUSY_TIMEOUT=3000;QSQLITE_OPEN_READONLY" : "QSQLITE_BUSY_TIMEOUT=3000");
        db.open();
    }
    ~WorkerConnection()
    {
        db.close();
        db = {};
        QSqlDatabase::removeDatabase(name);
    }
    WorkerConnection(const WorkerConnection &) = delete;
    WorkerConnection &operator=(const WorkerConnection &) = delete;
};
