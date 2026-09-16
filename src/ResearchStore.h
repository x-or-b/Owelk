#pragma once

#include <QObject>
#include <QRectF>
#include <QSqlDatabase>
#include <QThreadPool>
#include <QUrl>
#include <QVariantList>
#include <QVariantMap>

class ResearchStore final : public QObject
{
    Q_OBJECT
    Q_PROPERTY(QVariantMap session READ session CONSTANT)
    Q_PROPERTY(QVariantList captures READ captures NOTIFY capturesChanged)
    Q_PROPERTY(QVariantList recentDocuments READ recentDocuments NOTIFY recentDocumentsChanged)
    Q_PROPERTY(bool busy READ busy NOTIFY busyChanged)
    Q_PROPERTY(QString dataDirectory READ dataDirectory CONSTANT)
    Q_PROPERTY(QVariantList recentWorkspaces READ recentWorkspaces NOTIFY homeChanged)
    Q_PROPERTY(QVariantMap continueReading READ continueReading NOTIFY homeChanged)

public:
    explicit ResearchStore(const QString &directory, QObject *parent = nullptr);
    ~ResearchStore() override;
    bool initialize(QString *error);
    QVariantMap session() const;
    QVariantList captures() const { return m_captures; }
    QVariantList recentDocuments() const;
    bool busy() const { return m_pending > 0; }
    QString dataDirectory() const { return m_directory; }

    Q_INVOKABLE bool saveSession(const QVariantMap &state);
    Q_INVOKABLE bool rememberDocument(const QUrl &url);
    Q_INVOKABLE QString fileName(const QUrl &url) const;
    Q_INVOKABLE void captureRegion(const QUrl &source, int page, const QRectF &normalizedRegion);
    Q_INVOKABLE void openCapture(const QString &id);
    Q_INVOKABLE void copyText(const QString &text);
    Q_INVOKABLE int listFolder(const QUrl &folder);
    Q_INVOKABLE QVariantMap readingPosition(const QUrl &source) const;
    Q_INVOKABLE QVariantList searchKnowledge(const QString &query) const;
    Q_INVOKABLE QString createWorkspace(const QString &name);
    Q_INVOKABLE QVariantMap loadWorkspace(const QString &id);
    Q_INVOKABLE bool saveWorkspace(const QString &id, const QVariantMap &state);
    QVariantList recentWorkspaces() const;
    QVariantMap continueReading() const;

signals:
    void capturesChanged();
    void recentDocumentsChanged();
    void busyChanged();
    void message(const QString &text);
    void captureSaved(const QString &id);
    void sourceReady(const QUrl &source, int page, const QRectF &region);
    void folderLoaded(int requestId, const QUrl &folder, const QVariantList &entries, const QString &error);
    void homeChanged();

private:
    void reloadCaptures();
    QString m_directory;
    QString m_connection;
    QSqlDatabase m_database;
    QVariantList m_captures;
    QThreadPool m_workers;
    int m_pending = 0;
    int m_folderRequest = 0;
};
