#include "ChatGptAccount.h"
#include "Keychain.h"
#include "ResearchStore.h"
#include "UiText.h"

#include <QCryptographicHash>
#include <QDebug>
#include <QDesktopServices>
#include <QJsonArray>
#include <QJsonDocument>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QRandomGenerator>
#include <QTcpServer>
#include <QTcpSocket>
#include <QTimer>
#include <QUrlQuery>
#include <QUuid>
#include <utility>

namespace {
// What the tokens are for (sent as resource, also when the API address is changed for tests) and who issues them.
const QString resource = QStringLiteral("https://api.openai.com/v1");
const QString issuer = QStringLiteral("https://auth.openai.com");
// The identity, a refresh token, and permission to use the reader's plan for Responses requests.
const QString scopes = QStringLiteral("openid profile email offline_access resource.invoke chatgpt.tokens.use.direct");
const QString keyringAccount = QStringLiteral("chatgpt-refresh-token");
const int signInMinutes = 10;

QString randomToken()
{
    QByteArray bytes(32, Qt::Uninitialized);
    QRandomGenerator::system()->generate(
        reinterpret_cast<quint32 *>(bytes.data()), reinterpret_cast<quint32 *>(bytes.data() + bytes.size()));
    return QString::fromLatin1(bytes.toBase64(QByteArray::Base64UrlEncoding | QByteArray::OmitTrailingEquals));
}
QString challenge(const QString &verifier)
{
    return QString::fromLatin1(QCryptographicHash::hash(verifier.toLatin1(), QCryptographicHash::Sha256)
            .toBase64(QByteArray::Base64UrlEncoding | QByteArray::OmitTrailingEquals));
}
// Each value percent-encoded, for a query or a form body.
QByteArray encoded(const QList<std::pair<QString, QString>> &fields)
{
    QByteArrayList parts;
    for (const auto &[key, value] : fields) parts << key.toLatin1() + '=' + QUrl::toPercentEncoding(value);
    return parts.join('&');
}
QJsonObject jwtClaims(const QString &token)
{
    const auto parts = token.split('.');
    if (parts.size() < 2) return {};
    return QJsonDocument::fromJson(QByteArray::fromBase64(parts[1].toLatin1(), QByteArray::Base64UrlEncoding)).object();
}
// An OAuth error code: "error" as a string, or as an object with a code.
QString errorCode(const QJsonObject &json)
{
    const auto error = json.value("error");
    return error.isObject() ? error.toObject().value("code").toString() : error.toString();
}
QString errorText(const QJsonObject &json)
{
    const auto error = json.value("error");
    if (error.isObject()) return error.toObject().value("message").toString();
    return json.value("error_description").toString(error.toString());
}
void respond(QTcpSocket *socket, int status, const QString &text)
{
    const auto body = text.isEmpty() ? QByteArray()
                                     : "<!doctype html><meta charset=\"utf-8\"><title>Owelk</title>"
                                       "<body style=\"font:15px -apple-system,system-ui,sans-serif;margin:48px\"><p>"
            + text.toHtmlEscaped().toUtf8() + "</p></body>";
    socket->write("HTTP/1.1 " + QByteArray::number(status) + (status == 200 ? " OK" : " Not Found")
        + "\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\nContent-Length: "
        + QByteArray::number(body.size()) + "\r\n\r\n" + body);
    socket->disconnectFromHost();
}
}

ChatGptAccount::ChatGptAccount(ResearchStore *store, QNetworkAccessManager *network, QObject *parent)
    : QObject(parent), m_store(store), m_network(network)
{
}

bool ChatGptAccount::planUsage() const
{
    return m_store->setting("ai.chatgpt.planUsage") == "1";
}

bool ChatGptAccount::hasToken() const
{
    if (!m_hasToken) m_hasToken = !Keychain::read(keyringAccount, m_store->dataDirectory()).isEmpty();
    return *m_hasToken;
}

QVariantMap ChatGptAccount::state() const
{
    return {{"signedIn", signedIn()}, {"registered", hasToken()}, {"planUsage", planUsage()},
        {"email", m_store->setting("ai.chatgpt.email")}, {"pending", m_pending.has_value()}, {"error", m_error}};
}

void ChatGptAccount::report(const QString &error)
{
    // Kept for Settings, where the sign-in is started: the browser is in front when it fails.
    m_error = error;
    qWarning().noquote() << "ChatGPT sign-in:" << error;
    m_store->notify(error);
    emit changed();
}

QUrl ChatGptAccount::authBase() const
{
    // Tests point it at a local server; everything else signs in at OpenAI.
    auto value = m_store->setting("ai.authUrl.chatgpt", "https://auth.openai.com/");
    if (!value.endsWith('/')) value += '/';
    return QUrl(value);
}

QString ChatGptAccount::hostId()
{
    // One per installation (its data folder): OpenAI tells this computer's use apart from the reader's others.
    auto id = m_store->setting("ai.chatgpt.hostId");
    if (id.isEmpty()) {
        id = "urn:uuid:" + QUuid::createUuid().toString(QUuid::WithoutBraces);
        m_store->setSetting("ai.chatgpt.hostId", id);
    }
    return id;
}

void ChatGptAccount::signIn()
{
    stopListening();
    m_pending.reset();
    m_error.clear();
    auto *listener = new QTcpServer(this);
    // The port Codex uses first, any free one otherwise: only the port may change between sign-ins.
    if (!listener->listen(QHostAddress::LocalHost, 1455) && !listener->listen(QHostAddress::LocalHost)) {
        delete listener;
        report(ui("The ChatGPT sign-in could not start on this computer."));
        return;
    }
    m_listener = listener;
    Pending pending{randomToken(), randomToken(), randomToken(),
        QStringLiteral("http://127.0.0.1:%1/auth/callback").arg(listener->serverPort()),
        m_store->setting("ai.chatgpt.clientId")};
    QList<std::pair<QString, QString>> query;
    // The first sign-in registers Owelk with the account; later ones reuse the client id it was given.
    if (pending.clientId.isEmpty())
        query << std::pair{"client_id", "dynamic_agent_client"} << std::pair{"agent_name_hint", "Owelk"};
    else {
        query << std::pair{"client_id", pending.clientId};
        if (const auto email = m_store->setting("ai.chatgpt.email"); !email.isEmpty())
            query << std::pair{"login_hint", email};
    }
    query << std::pair{"ext_agent_host_id", hostId()} << std::pair{"response_type", "code"}
          << std::pair{"redirect_uri", pending.redirect} << std::pair{"scope", scopes}
          << std::pair{"resource", resource} << std::pair{"state", pending.state} << std::pair{"nonce", pending.nonce}
          << std::pair{"code_challenge_method", "S256"} << std::pair{"code_challenge", challenge(pending.verifier)};
    m_pending = pending;
    connect(listener, &QTcpServer::newConnection, this, &ChatGptAccount::accept);
    // A sign-in left open stops waiting.
    QTimer::singleShot(signInMinutes * 60000, listener, [this] {
        m_pending.reset();
        stopListening();
        emit changed();
    });
    emit changed();
    auto url = authBase().resolved(QUrl("api/accounts/authorize"));
    url.setQuery(QString::fromLatin1(encoded(query)), QUrl::StrictMode);
    // The browser signs in; an iPad build would open its in-app sign-in sheet here instead.
    QDesktopServices::openUrl(url);
}

void ChatGptAccount::stopListening()
{
    if (!m_listener) return;
    m_listener->close();
    m_listener->deleteLater();
    m_listener = nullptr;
}

void ChatGptAccount::accept()
{
    while (m_listener && m_listener->hasPendingConnections()) {
        auto *socket = m_listener->nextPendingConnection();
        // Owned here, so closing the listener does not take an answer still being written.
        socket->setParent(this);
        connect(socket, &QTcpSocket::disconnected, socket, &QObject::deleteLater);
        QTimer::singleShot(30000, socket, &QObject::deleteLater);
        connect(socket, &QTcpSocket::readyRead, socket, [this, socket] {
            if (socket->property("answered").toBool() || !socket->canReadLine()) return;
            socket->setProperty("answered", true);
            // GET /auth/callback?code=…&state=… HTTP/1.1: only the request line matters.
            const auto line = QString::fromLatin1(socket->readLine()).split(' ');
            const QUrl target(line.value(1));
            if (line.value(0) != "GET" || target.path() != "/auth/callback") {
                respond(socket, 404, {});
                return;
            }
            respond(socket, 200, callback(QUrlQuery(target)));
        });
    }
}

QString ChatGptAccount::callback(const QUrlQuery &query)
{
    // Only the answer to this attempt counts; anything else leaves it waiting.
    if (!m_pending || query.queryItemValue("state") != m_pending->state)
        return ui("This sign-in is no longer waiting. Start it again in Owelk.");
    const auto pending = *std::exchange(m_pending, std::nullopt);
    stopListening();
    emit changed();
    if (query.hasQueryItem("error")) {
        const auto description = query.queryItemValue("error_description", QUrl::FullyDecoded);
        report(query.queryItemValue("error") == "access_denied"
                ? ui("ChatGPT sign-in was cancelled.") + (description.isEmpty() ? QString() : " " + description)
                : ui("ChatGPT sign-in did not complete: ") + query.queryItemValue("error", QUrl::FullyDecoded)
                    + (description.isEmpty() ? QString() : " (" + description + ")"));
        return ui("Sign-in did not complete. You can close this tab.");
    }
    const auto issued = query.queryItemValue("client_id");
    if (pending.clientId.isEmpty() && issued.isEmpty()) {
        report(ui("ChatGPT did not finish registering Owelk. Try signing in again."));
        return ui("Sign-in did not complete. You can close this tab.");
    }
    // A later sign-in keeps the client it started with.
    if (!pending.clientId.isEmpty() && !issued.isEmpty() && issued != pending.clientId) {
        report(ui("ChatGPT answered for another registration. Try signing in again."));
        return ui("Sign-in did not complete. You can close this tab.");
    }
    exchange(query.queryItemValue("code", QUrl::FullyDecoded), pending.clientId.isEmpty() ? issued : pending.clientId,
        pending);
    return ui("Signed in. You can close this tab and return to Owelk.");
}

void ChatGptAccount::exchange(const QString &code, const QString &clientId, const Pending &pending)
{
    QNetworkRequest request(authBase().resolved(QUrl("api/accounts/oauth/token")));
    request.setHeader(QNetworkRequest::ContentTypeHeader, "application/x-www-form-urlencoded");
    request.setTransferTimeout(30000);
    auto *reply = m_network->post(request,
        encoded({{"grant_type", "authorization_code"}, {"client_id", clientId}, {"code", code},
            {"code_verifier", pending.verifier}, {"redirect_uri", pending.redirect}, {"resource", resource}}));
    connect(reply, &QNetworkReply::finished, this, [this, reply, clientId, nonce = pending.nonce] {
        reply->deleteLater();
        const auto json = QJsonDocument::fromJson(reply->readAll()).object();
        const int status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        if (status != 200) {
            const auto detail = errorText(json);
            report(ui("ChatGPT sign-in did not complete: ")
                + (status ? QStringLiteral("HTTP %1").arg(status) : reply->errorString())
                + (detail.isEmpty() ? QString() : " · " + detail));
            return;
        }
        // The ID token came straight from the token endpoint over TLS, so its signature need not be checked
        // (OpenID Connect Core 3.1.3.7, item 6); its issuer, audience, expiry and nonce are.
        const auto claims = jwtClaims(json.value("id_token").toString());
        const auto audience = claims.value("aud");
        const bool forUs = audience.isArray() ? audience.toArray().contains(clientId) : audience.toString() == clientId;
        // Which check failed, so a report can say (claim names only, never a token).
        const auto failedCheck = claims.isEmpty()       ? QStringLiteral("no ID token")
            : claims.value("iss").toString() != issuer  ? "issuer " + claims.value("iss").toString()
            : !forUs                                    ? QStringLiteral("audience")
            : claims.value("nonce").toString() != nonce ? QStringLiteral("nonce")
            : claims.value("exp").toInteger() <= QDateTime::currentSecsSinceEpoch() ? QStringLiteral("expiry")
                                                                                    : QString();
        if (!failedCheck.isEmpty()) {
            report(QString(ui("ChatGPT sign-in could not be verified (%1). Try signing in again.")).arg(failedCheck));
            return;
        }
        const auto subject = claims.value("sub").toString();
        const auto known = m_store->setting("ai.chatgpt.subject");
        if (!known.isEmpty() && known != subject && m_store->setting("ai.chatgpt.clientId") == clientId) {
            // Another account came back for this registration: the next sign-in registers it anew.
            m_store->setSetting("ai.chatgpt.clientId", QString());
            report(ui("That ChatGPT account is not the one signed in before. Continue with ChatGPT again to use it."));
            return;
        }
        if (!keep(json)) return;
        const bool plan = json.value("scope").toString().split(' ').contains("chatgpt.tokens.use.direct");
        m_store->setSetting("ai.chatgpt.clientId", clientId);
        m_store->setSetting("ai.chatgpt.subject", subject);
        m_store->setSetting("ai.chatgpt.email", claims.value("email").toString());
        m_store->setSetting("ai.chatgpt.planUsage", plan ? "1" : "0");
        m_error.clear();
        if (!plan)
            m_store->notify(ui("Signed in, but ChatGPT plan use was not allowed. Continue with ChatGPT again and "
                               "allow it, or use an API key."));
        else if (m_store->setting("ai.chatgpt.welcomed") != "1") {
            m_store->setSetting("ai.chatgpt.welcomed", "1");
            m_store->notify(ui("You're using your ChatGPT plan. Manage its use at chatgpt.com/settings/usage."));
        }
        emit changed();
    });
}

bool ChatGptAccount::keep(const QJsonObject &tokens)
{
    const auto refreshToken = tokens.value("refresh_token").toString();
    if (refreshToken.isEmpty() || !Keychain::write(keyringAccount, refreshToken, m_store->dataDirectory())) {
        report(refreshToken.isEmpty()
                ? ui("ChatGPT did not allow Owelk to stay signed in.")
                : QString(ui("Cannot store the ChatGPT sign-in in %1.")).arg(Keychain::storageName()));
        return false;
    }
    m_hasToken = true;
    m_accessToken = tokens.value("access_token").toString();
    m_expires = QDateTime::currentDateTimeUtc().addSecs(tokens.value("expires_in").toInt(3600));
    return true;
}

void ChatGptAccount::forgetTokens()
{
    Keychain::remove(keyringAccount, m_store->dataDirectory());
    m_hasToken = false;
    m_accessToken.clear();
}

void ChatGptAccount::withAccessToken(QObject *context, TokenCallback callback)
{
    if (!m_accessToken.isEmpty() && QDateTime::currentDateTimeUtc().secsTo(m_expires) > 60) {
        callback(m_accessToken, {});
        return;
    }
    m_waiting.append({context, std::move(callback)});
    if (!m_refreshing) refresh();
}

void ChatGptAccount::refresh()
{
    const auto token = Keychain::read(keyringAccount, m_store->dataDirectory());
    const auto clientId = m_store->setting("ai.chatgpt.clientId");
    if (token.isEmpty() || clientId.isEmpty()) {
        answer({}, ui("Continue with ChatGPT in Settings → AI."));
        return;
    }
    m_refreshing = true;
    QNetworkRequest request(authBase().resolved(QUrl("api/accounts/oauth/token")));
    request.setHeader(QNetworkRequest::ContentTypeHeader, "application/x-www-form-urlencoded");
    request.setTransferTimeout(30000);
    auto *reply = m_network->post(request,
        encoded({{"grant_type", "refresh_token"}, {"client_id", clientId}, {"refresh_token", token},
            {"resource", resource}}));
    connect(reply, &QNetworkReply::finished, this, [this, reply] {
        reply->deleteLater();
        m_refreshing = false;
        const auto json = QJsonDocument::fromJson(reply->readAll()).object();
        const int status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        if (status == 200 && keep(json)) {
            answer(m_accessToken, {});
            return;
        }
        // A refresh token that can no longer be used ends the sign-in; a network or server failure keeps it.
        static const QStringList ended{"invalid_grant", "invalid_refresh_token", "token_expired",
            "refresh_token_expired", "refresh_token_invalidated", "refresh_token_reused", "invalid_client"};
        const auto code = errorCode(json);
        if (status >= 400 && status < 500 && (ended.contains(code) || status == 401)) {
            forgetTokens();
            // A client OpenAI no longer accepts is registered anew next time.
            if (code == "invalid_client") m_store->setSetting("ai.chatgpt.clientId", QString());
            m_error = ui("The ChatGPT sign-in has ended. Continue with ChatGPT again in Settings → AI.");
            emit changed();
            answer({}, m_error);
            return;
        }
        answer({},
            ui("Cannot reach ChatGPT. Check the connection.")
                + (status ? QStringLiteral(" (%1)").arg(status) : QString()));
    });
}

void ChatGptAccount::answer(const QString &token, const QString &error)
{
    for (const auto &[context, callback] : std::exchange(m_waiting, {}))
        if (context) callback(token, error);
}

void ChatGptAccount::signOut()
{
    const auto token = Keychain::read(keyringAccount, m_store->dataDirectory());
    const auto clientId = m_store->setting("ai.chatgpt.clientId");
    // Signed out here at once; the registration (client id, email, host id) stays for the next sign-in.
    forgetTokens();
    m_store->setSetting("ai.chatgpt.planUsage", QString());
    emit changed();
    if (token.isEmpty()) return;
    // The session also ends at OpenAI: its revocation address comes from OpenAI's published configuration.
    QNetworkRequest discovery(authBase().resolved(QUrl(".well-known/openid-configuration")));
    discovery.setTransferTimeout(15000);
    auto *reply = m_network->get(discovery);
    connect(reply, &QNetworkReply::finished, this, [this, reply, token, clientId] {
        reply->deleteLater();
        const QUrl endpoint(QJsonDocument::fromJson(reply->readAll()).object().value("revocation_endpoint").toString());
        const auto unconfirmed = [this] {
            m_store->notify(ui("Signed out here, but OpenAI did not confirm it. You can disconnect Owelk in ChatGPT "
                               "settings."));
        };
        if (!endpoint.isValid() || endpoint.isRelative()) {
            unconfirmed();
            return;
        }
        QNetworkRequest request(endpoint);
        request.setHeader(QNetworkRequest::ContentTypeHeader, "application/x-www-form-urlencoded");
        request.setTransferTimeout(15000);
        auto *revoke = m_network->post(
            request, encoded({{"token", token}, {"token_type_hint", "refresh_token"}, {"client_id", clientId}}));
        connect(revoke, &QNetworkReply::finished, this, [revoke, unconfirmed] {
            revoke->deleteLater();
            if (revoke->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt() != 200) unconfirmed();
        });
    });
}
