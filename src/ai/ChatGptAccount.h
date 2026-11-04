#pragma once

#include <QDateTime>
#include <QJsonObject>
#include <QList>
#include <QObject>
#include <QPointer>
#include <QUrl>
#include <QVariantMap>
#include <functional>
#include <optional>

class QNetworkAccessManager;
class QNetworkReply;
class QTcpServer;
class QTcpSocket;
class QUrlQuery;
class ResearchStore;

// Sign in with ChatGPT for open-source apps (developers.openai.com/siwc): answers sent to OpenAI's Responses API
// are paid by the reader's ChatGPT plan. The browser signs in on OpenAI's own page and comes back to a listener on
// 127.0.0.1 (OAuth with PKCE); Owelk never sees the password. Only the refresh token is kept, in the system
// keyring (the Windows one holds 2.5 KB at most); the hour-long access token stays in memory, and the rest of the
// registration (client id, email, this computer's host id) sits in the settings.
class ChatGptAccount final : public QObject {
    Q_OBJECT
public:
    ChatGptAccount(ResearchStore *store, QNetworkAccessManager *network, QObject *parent = nullptr);
    // Signed in with permission to use the plan: requests can be made.
    bool signedIn() const { return hasToken() && planUsage(); }
    // signedIn, email, planUsage (false: signed in without the plan's permission), pending (the browser is open).
    QVariantMap state() const;
    // Opens the browser on OpenAI's sign-in page; changed() follows when it comes back, or fails.
    void signIn();
    // Ends the session at OpenAI (revokes the refresh token) and forgets the tokens here. The registration stays
    // for the next sign-in.
    void signOut();
    using TokenCallback = std::function<void(const QString &token, const QString &error)>;
    // A valid access token, refreshed first when it is about to expire (one refresh at a time). The callback runs
    // only while context exists.
    void withAccessToken(QObject *context, TokenCallback callback);
signals:
    void changed();

private:
    struct Pending {
        QString state, nonce, verifier, redirect;
        // Empty on the first registration, when the callback brings the issued one.
        QString clientId;
    };
    bool planUsage() const;
    // A refresh token is kept (the keyring is read once, when first asked).
    bool hasToken() const;
    QUrl authBase() const;
    QString hostId();
    void stopListening();
    void accept();
    // The browser came back: the text for its page.
    QString callback(const QUrlQuery &query);
    void exchange(const QString &code, const QString &clientId, const Pending &pending);
    void refresh();
    void answer(const QString &token, const QString &error);
    // Keeps a token response's access and refresh tokens; false (and a message) when the keyring refuses.
    bool keep(const QJsonObject &tokens);
    void forgetTokens();
    ResearchStore *m_store;
    QNetworkAccessManager *m_network;
    QPointer<QTcpServer> m_listener;
    std::optional<Pending> m_pending;
    QString m_accessToken;
    QDateTime m_expires;
    mutable std::optional<bool> m_hasToken;
    bool m_refreshing = false;
    QList<QPair<QPointer<QObject>, TokenCallback>> m_waiting;
};
