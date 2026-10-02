#include "AiService.h"
#include "AcpAgent.h"
#include "AiContext.h"
#include "AiProviders.h"
#include "Keychain.h"
#include "ResearchStore.h"

#include <QBuffer>
#include <QClipboard>
#include <QMimeData>
#include <QDesktopServices>
#include <QGuiApplication>
#include <QImage>
#include <QUuid>
#include <QDir>
#include <QProcess>
#include <QStandardPaths>
#include <QFile>
#include <QFileInfo>
#include <QFutureWatcher>
#include <QJsonArray>
#include <QJsonDocument>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QPdfDocument>
#include <QPdfSelection>
#include <QRegularExpression>
#include <QtConcurrent>
#include <algorithm>

namespace {
struct ProviderInfo {
    const char *id, *name, *kind, *sends, *defaultModel, *defaultBase;
};
// Claude login is not offered: Anthropic does not allow third-party apps to provide claude.ai sign-in.
const ProviderInfo providerTable[] = {
    {"claude", "Claude API", "api", "Anthropic", "claude-opus-5-5", "https://api.anthropic.com/"},
    {"openai", "OpenAI API", "api", "OpenAI", "gpt-5", "https://api.openai.com/"},
    {"codex", "ChatGPT account (Codex)", "account", "OpenAI via your ChatGPT account", "", ""},
    {"ollama", "Ollama (local)", "local", "this Mac only", "", "http://127.0.0.1:11434/"},
    {"claude-agent", "Claude Agent (ACP)", "agent", "Anthropic via Claude Agent", "", ""},
    {"codex-agent", "Codex Agent (ACP)", "agent", "OpenAI via Codex Agent", "", ""},
    {"gemini-agent", "Gemini CLI (ACP)", "agent", "Google via Gemini CLI", "", ""},
};
// Finder-started apps do not see the shell PATH; look where Homebrew and the Node installer put tools.
QString findTool(const QString &name)
{
    auto found = QStandardPaths::findExecutable(name);
    for (const auto &directory : {QStringLiteral("/opt/homebrew/bin"), QStringLiteral("/usr/local/bin")})
        if (found.isEmpty() && QFileInfo(directory + "/" + name).isExecutable()) found = directory + "/" + name;
    return found;
}
QString npmExecutable()
{
    const auto override = qEnvironmentVariable("OWELK_NPM");
    return override.isEmpty() ? findTool("npm") : override;
}
const ProviderInfo *info(const QString &id)
{
    for (const auto &entry : providerTable)
        if (id == QLatin1String(entry.id)) return &entry;
    return nullptr;
}
QString pdfText(QPdfDocument &pdf, int page)
{
    return pdf.getAllText(page).text().simplified();
}
}

AiService::AiService(ResearchStore *store, QObject *parent)
    : QObject(parent), m_store(store), m_network(new QNetworkAccessManager(this)), m_codex(new CodexBridge(this))
{
    connect(m_codex, &CodexBridge::notification, this, [this](const QString &method, const QJsonObject &params) {
        if (method == "account/login/completed") {
            if (!params.value("success").toBool())
                m_store->notify("ChatGPT sign-in did not complete: " + params.value("error").toString("cancelled"));
            refreshCodexAccount();
        } else if (method == "account/updated")
            refreshCodexAccount();
    });
}

AiService::~AiService()
{
    if (m_installing) m_installing->disconnect(this);
    for (const auto &provider : std::as_const(m_running))
        if (provider) provider->disconnect(this);
}

QVariantList AiService::providers() const
{
    QVariantList rows;
    for (const auto &entry : providerTable) {
        const QString id = entry.id;
        bool configured = true;
        if (QString(entry.kind) == "api")
            configured = hasApiKey(id);
        else if (id == "codex")
            configured = m_codexAccount.value("signedIn").toBool();
        const bool agent = QString(entry.kind) == "agent";
        // Claude Agent runs on the Claude API key; the other agents sign in on their own.
        if (agent) configured = agentInstalled(id) && (id != "claude-agent" || hasApiKey("claude"));
        rows.append(QVariantMap{{"id", id}, {"name", entry.name}, {"kind", entry.kind}, {"sends", entry.sends},
            {"configured", configured}, {"model", model(id)}, {"defaultModel", entry.defaultModel},
            {"consented", consented(id)}, {"installed", !agent || agentInstalled(id)}});
    }
    return rows;
}

QString AiService::provider() const
{
    const auto id = m_store->setting("ai.provider", "claude");
    return info(id) ? id : QStringLiteral("claude");
}

void AiService::setProvider(const QString &id)
{
    if (!info(id) || id == provider()) return;
    m_store->setSetting("ai.provider", id);
    emit providersChanged();
}

QString AiService::model(const QString &provider) const
{
    const auto *entry = info(provider);
    return m_store->setting("ai.model." + provider, entry ? entry->defaultModel : "");
}

void AiService::setModel(const QString &provider, const QString &model)
{
    if (!info(provider)) return;
    m_store->setSetting("ai.model." + provider, model.trimmed().left(120));
    emit providersChanged();
}

QString AiService::keyAccount(const QString &provider) const
{
    return provider + "-api-key";
}

bool AiService::setApiKey(const QString &provider, const QString &key)
{
    const auto *entry = info(provider);
    const auto trimmed = key.trimmed();
    if (!entry || QString(entry->kind) != "api" || trimmed.size() < 8 || trimmed.size() > 400) return false;
    const bool ok = Keychain::write(keyAccount(provider), trimmed, m_store->dataDirectory());
    if (!ok) m_store->notify("Cannot store the API key in the Keychain.");
    emit providersChanged();
    return ok;
}

bool AiService::hasApiKey(const QString &provider) const
{
    return !Keychain::read(keyAccount(provider), m_store->dataDirectory()).isEmpty();
}

bool AiService::clearApiKey(const QString &provider)
{
    const bool ok = Keychain::remove(keyAccount(provider), m_store->dataDirectory());
    emit providersChanged();
    return ok;
}

bool AiService::consented(const QString &provider) const
{
    // Local Ollama keeps everything on this Mac.
    return provider == "ollama" || m_store->setting("ai.consent." + provider) == "1";
}

void AiService::giveConsent(const QString &provider)
{
    if (!info(provider)) return;
    m_store->setSetting("ai.consent." + provider, "1");
    emit providersChanged();
}

QUrl AiService::baseUrl(const QString &provider) const
{
    // Tests (and a non-default Ollama host) override the address; everything else uses the official endpoint.
    const auto *entry = info(provider);
    auto value = m_store->setting("ai.baseUrl." + provider, entry ? entry->defaultBase : "");
    if (!value.endsWith('/')) value += '/';
    return QUrl(value);
}

AiProvider *AiService::createProvider(const QString &provider, QString *error)
{
    if (provider == "claude" || provider == "openai") {
        const auto key = Keychain::read(keyAccount(provider), m_store->dataDirectory());
        if (key.isEmpty()) {
            *error = QStringLiteral("Add your %1 key in Settings → AI.").arg(info(provider)->name);
            return nullptr;
        }
        if (provider == "claude") return new AnthropicProvider(m_network, baseUrl(provider), key, this);
        return new OpenAiProvider(m_network, baseUrl(provider), key, this);
    }
    if (provider == "ollama") return new OllamaProvider(m_network, baseUrl(provider), this);
    if (provider == "codex") return new CodexProvider(m_codex, this);
    if (const auto *agent = acpAgent(provider)) {
        if (!agentInstalled(provider)) {
            *error = QStringLiteral("Install %1 in Settings → AI.").arg(agent->name);
            return nullptr;
        }
        if (provider == "claude-agent" && !hasApiKey("claude")) {
            *error = "Claude Agent needs a Claude API key. Add it in Settings → AI → Claude Agent.";
            return nullptr;
        }
        return new AcpProvider(agentBridge(provider), agent->name, this);
    }
    *error = "Choose an AI provider in Settings → AI.";
    return nullptr;
}

int AiService::ask(const QVariantMap &input)
{
    const int request = ++m_nextRequest;
    auto spec = input;
    const auto id = spec.value("provider").toString().isEmpty() ? provider() : spec.value("provider").toString();
    const auto fail = [this, request](const QString &error) {
        QMetaObject::invokeMethod(this, [this, request, error] { emit failed(request, error); }, Qt::QueuedConnection);
        return request;
    };
    if (!info(id)) return fail("Choose an AI provider in Settings → AI.");
    if (!consented(id)) return fail("Review what is sent to this provider before the first request.");
    if ((id == "ollama") && model(id).isEmpty()) return fail("Choose an Ollama model in Settings → AI.");
    if (spec.value("threadId").toString().isEmpty() || m_store->aiThread(spec.value("threadId").toString()).isEmpty()) {
        static const QHash<QString, QString> labels{{"explain", "Explain"}, {"translate", "Translate"},
            {"summarize", "Summarize"}, {"figure", "Explain figure"}};
        const auto question = spec.value("question").toString().simplified();
        auto title = labels.value(spec.value("action").toString());
        const auto source = spec.value("source").toUrl();
        if (title.isEmpty())
            title = question.left(80);
        else if (source.isValid() && !source.isEmpty())
            title += " · " + m_store->displayName(source);
        const auto thread
            = m_store->createAiThread({{"title", title}, {"provider", id}, {"model", model(id)}, {"source", source}});
        if (thread.isEmpty()) return fail("Cannot start an AI thread.");
        spec.insert("threadId", thread);
    }
    // Gather on the UI thread what the store knows; PDF text and images are read on a worker.
    const QUrl source = spec.value("source").toUrl();
    QVariantMap prepared;
    if (source.isValid() && !source.isEmpty()) {
        const auto details = m_store->documentDetails(source);
        prepared.insert({{"title", m_store->displayName(source)}, {"authors", details.value("authors")},
            {"year", details.value("year")}});
    }
    QStringList imagePaths;
    const auto captureId = spec.value("captureId").toString();
    for (const auto &value : m_store->captures()) {
        const auto capture = value.toMap();
        if (captureId.isEmpty() || capture.value("id").toString() != captureId) continue;
        if (capture.value("kind").toString() == "text")
            spec.insert("selection", capture.value("text"));
        else if (capture.value("imageAvailable").toBool())
            imagePaths << capture.value("image").toUrl().toLocalFile();
        if (!capture.value("caption").toString().isEmpty()) spec.insert("selection", capture.value("caption"));
        if (!source.isValid() || source.isEmpty()) {
            spec.insert("source", capture.value("source"));
            prepared.insert("title", capture.value("name"));
        }
    }
    // Images the reader attached (files, drops, pasted screenshots).
    QStringList userImages;
    for (const auto &value : spec.value("imageFiles").toList()) {
        const auto path
            = QUrl(value.toString()).isLocalFile() ? QUrl(value.toString()).toLocalFile() : value.toString();
        if (QFileInfo(path).isFile() && userImages.size() < 6) userImages << path;
    }
    const auto attachments = attachmentDirectory();
    QStringList notes;
    for (const auto &noteId : spec.value("noteIds").toStringList())
        notes << m_store->note(noteId).value("body").toString();
    prepared.insert("notes", notes);
    m_running.insert(request, nullptr);
    emit busyChanged();
    struct Material {
        QString pageText, paperText, error;
        QList<QByteArray> images;
        QStringList paths;
    };
    const auto pdfSource = spec.value("source").toUrl();
    const auto scope = spec.value("scope").toString();
    const int page = spec.value("page").toInt();
    auto *watcher = new QFutureWatcher<Material>(this);
    connect(watcher, &QFutureWatcher<Material>::finished, this, [this, watcher, request, id, spec, prepared] {
        const auto material = watcher->result();
        watcher->deleteLater();
        if (!m_running.contains(request)) return; // Cancelled while reading.
        if (!material.error.isEmpty()) {
            m_running.remove(request);
            emit busyChanged();
            emit failed(request, material.error);
            return;
        }
        auto next = prepared;
        next.insert("pageText", material.pageText);
        next.insert("paperText", material.paperText);
        QVariantList images;
        for (qsizetype i = 0; i < material.images.size(); ++i)
            images.append(QVariantMap{{"data", material.images[i]}, {"path", material.paths.value(i)}});
        next.insert("images", images);
        run(request, id, spec, next);
    });
    watcher->setFuture(QtConcurrent::run([pdfSource, scope, page, imagePaths, userImages, attachments] {
        Material material;
        if (pdfSource.isLocalFile() && (scope == "page" || scope == "paper")) {
            QPdfDocument pdf;
            if (pdf.load(pdfSource.toLocalFile()) != QPdfDocument::Error::None) {
                material.error = "Cannot read the PDF for this request.";
                return material;
            }
            if (scope == "page" && page >= 0 && page < pdf.pageCount()) material.pageText = pdfText(pdf, page);
            if (scope == "paper") {
                // Leading pages carry the abstract, method and results; the budget trims the rest.
                for (int i = 0; i < pdf.pageCount() && material.paperText.size() < 80000; ++i)
                    material.paperText += QStringLiteral("[Page %1] ").arg(i + 1) + pdfText(pdf, i) + "\n";
            }
        }
        for (const auto &path : imagePaths) {
            QFile file(path);
            if (file.open(QIODevice::ReadOnly) && file.size() < 8 * 1024 * 1024) {
                material.images << file.readAll();
                material.paths << path;
            }
        }
        // Any common format becomes a PNG at most 1568 px on its long side (what vision models use);
        // the copy in the attachments folder is what file-based providers read.
        for (const auto &path : userImages) {
            QImage image(path);
            if (image.isNull()) {
                material.error = "Cannot read the image " + QFileInfo(path).fileName() + ".";
                return material;
            }
            if (std::max(image.width(), image.height()) > 1568)
                image = image.scaled(1568, 1568, Qt::KeepAspectRatio, Qt::SmoothTransformation);
            QByteArray png;
            QBuffer buffer(&png);
            buffer.open(QIODevice::WriteOnly);
            image.save(&buffer, "PNG");
            const auto copy = attachments + "/" + QUuid::createUuid().toString(QUuid::WithoutBraces) + ".png";
            QFile out(copy);
            if (out.open(QIODevice::WriteOnly)) out.write(png);
            material.images << png;
            material.paths << copy;
        }
        return material;
    }));
    return request;
}

void AiService::run(int request, const QString &id, const QVariantMap &spec, const QVariantMap &prepared)
{
    const auto threadId = spec.value("threadId").toString();
    QList<AiTurn> history;
    for (const auto &value : m_store->aiThread(threadId).value("messages").toList()) {
        const auto message = value.toMap();
        history.append({message.value("role").toString(), message.value("content").toString()});
    }
    AiMaterials materials;
    // The paper's details introduce the first turn; later turns already carry them.
    if (history.isEmpty()) {
        materials.title = prepared.value("title").toString();
        materials.authors = prepared.value("authors").toString();
        materials.year = prepared.value("year").toString();
    }
    materials.selection = spec.value("selection").toString();
    materials.pageText = prepared.value("pageText").toString();
    materials.paperText = prepared.value("paperText").toString();
    materials.notes = prepared.value("notes").toStringList();
    materials.pageNumber = spec.value("scope").toString() == "page" ? spec.value("page").toInt() + 1 : 0;
    const auto images = prepared.value("images").toList();
    materials.hasImage = !images.isEmpty();
    const auto action = spec.value("action").toString();
    const auto prompt = buildAiPrompt(action.isEmpty() ? QStringLiteral("ask") : action,
        m_store->setting("aiLanguage", "ko"), spec.value("question").toString(), materials);
    QString error;
    auto *provider = createProvider(id, &error);
    if (!provider) {
        m_running.remove(request);
        emit busyChanged();
        emit failed(request, error);
        return;
    }
    AiRequest call;
    call.system = prompt.system;
    call.history = history;
    call.text = prompt.text;
    call.model = spec.value("model").toString().isEmpty() ? model(id) : spec.value("model").toString().left(120);
    // Provider level names only (low, medium, xhigh, …); anything else is ignored.
    static const QRegularExpression level("^[a-z_-]{1,16}$");
    const auto effort = spec.value("effort").toString();
    if (level.match(effort).hasMatch()) call.effort = effort;
    call.fast = spec.value("fast").toBool();
    for (const auto &value : images) {
        const auto image = value.toMap();
        call.images.append({image.value("data").toByteArray(), "image/png", image.value("path").toString()});
    }
    m_running.insert(request, provider);
    const auto done = [this, request, provider] {
        m_running.remove(request);
        provider->deleteLater();
        emit busyChanged();
    };
    connect(provider, &AiProvider::delta, this, [this, request](const QString &text) { emit delta(request, text); });
    connect(provider, &AiProvider::finished, this,
        [this, request, id, prompt, spec, done, threadId, attached = materials](
            const QString &text, const QString &used) {
            done();
            // A turn is stored only when it completed, so a thread always alternates question and answer.
            const auto usedModel = used.isEmpty() ? model(id) : used;
            static const QHash<QString, QString> labels{{"explain", "Explain"}, {"translate", "Translate"},
                {"summarize", "Summarize"}, {"figure", "Explain figure"}};
            auto display = spec.value("question").toString().trimmed();
            if (display.isEmpty()) display = labels.value(spec.value("action").toString(), "Ask");
            QStringList attachments;
            if (!attached.selection.isEmpty()) attachments << "selection";
            if (!attached.pageText.isEmpty()) attachments << QStringLiteral("page %1").arg(attached.pageNumber);
            if (!attached.paperText.isEmpty()) attachments << "paper";
            if (attached.hasImage) attachments << "image";
            m_store->appendAiMessage(threadId,
                {{"role", "user"}, {"content", prompt.text}, {"display", display}, {"provider", id},
                    {"model", usedModel},
                    {"context",
                        QVariantMap{{"attachments", attachments}, {"captureId", spec.value("captureId")},
                            {"selection", attached.selection.left(400)}, {"page", spec.value("page")}}}});
            m_store->appendAiMessage(
                threadId, {{"role", "assistant"}, {"content", text}, {"model", usedModel}, {"provider", id}});
            emit finished(request, text,
                {{"provider", id}, {"model", usedModel}, {"prompt", prompt.text}, {"threadId", threadId},
                    {"action", spec.value("action")}, {"question", spec.value("question")},
                    {"source", spec.value("source")}, {"page", spec.value("page")},
                    {"captureId", spec.value("captureId")}});
        });
    connect(provider, &AiProvider::failed, this, [this, request, done](const QString &message) {
        done();
        emit failed(request, message);
    });
    emit started(request, threadId, id, call.model, prompt.truncated);
    provider->start(call);
}

void AiService::cancel(int request)
{
    if (!m_running.contains(request)) return;
    const auto provider = m_running.value(request);
    if (provider)
        provider->cancel();
    else {
        m_running.remove(request);
        emit busyChanged();
        emit failed(request, "Stopped.");
    }
}

void AiService::testConnection(const QString &id)
{
    QString error;
    if (!info(id)) return;
    auto *provider = createProvider(id, &error);
    if (!provider) {
        emit connectionTested(id, false, error);
        return;
    }
    connect(provider, &AiProvider::finished, this, [this, id, provider](const QString &text, const QString &used) {
        provider->deleteLater();
        emit connectionTested(
            id, true, QStringLiteral("Connected (%1): %2").arg(used.isEmpty() ? model(id) : used, text.left(80)));
    });
    connect(provider, &AiProvider::failed, this, [this, id, provider](const QString &message) {
        provider->deleteLater();
        emit connectionTested(id, false, message);
    });
    AiRequest call;
    call.system = "Reply with the single word: ok";
    call.text = "Connection test.";
    call.model = model(id);
    call.maxTokens = 64;
    provider->start(call);
}

void AiService::refreshCodexAccount()
{
    m_codex->call("account/read", {}, [this](const QJsonValue &result, const QString &error) {
        const auto account = result.toObject().value("account").toObject();
        m_codexAccount = {{"available", error.isEmpty() || !error.contains("Codex")}, {"error", error},
            {"signedIn", account.value("type").toString() == "chatgpt" || account.value("type").toString() == "apiKey"},
            {"email", account.value("email").toString()}, {"plan", account.value("planType").toString()}};
        if (!error.isEmpty()) m_codexAccount.insert("available", false);
        emit codexAccountChanged(m_codexAccount);
        emit providersChanged();
    });
}

void AiService::codexSignIn()
{
    m_codex->call("account/login/start", {{"type", "chatgpt"}}, [this](const QJsonValue &result, const QString &error) {
        if (!error.isEmpty()) {
            m_store->notify(error);
            return;
        }
        // The browser completes OpenAI's own sign-in page; Owelk never sees the password.
        const QUrl url(result.toObject().value("authUrl").toString());
        if (url.scheme() == "https")
            QDesktopServices::openUrl(url);
        else
            m_store->notify("Codex did not return a sign-in address.");
    });
}

void AiService::codexSignOut()
{
    m_codex->call("account/logout", {}, [this](const QJsonValue &, const QString &) { refreshCodexAccount(); });
}

void AiService::listOllamaModels()
{
    auto *reply = m_network->get(QNetworkRequest(baseUrl("ollama").resolved(QUrl("api/tags"))));
    connect(reply, &QNetworkReply::finished, this, [this, reply] {
        reply->deleteLater();
        QStringList models;
        for (const auto &value : QJsonDocument::fromJson(reply->readAll()).object().value("models").toArray())
            models << value.toObject().value("name").toString();
        if (models.isEmpty() && reply->error() != QNetworkReply::NoError)
            m_store->notify("Ollama is not running on this Mac (" + baseUrl("ollama").toString() + ").");
        emit ollamaModelsLoaded(models);
    });
}

void AiService::listModels(const QString &provider)
{
    if (provider == "claude") {
        // Anthropic's current models; the first is the default. Haiku has no effort levels, and only
        // Opus offers fast mode.
        const QStringList levels{"low", "medium", "high", "xhigh", "max"};
        emit modelsLoaded(provider,
            {QVariantMap{{"id", "claude-opus-5-5"}, {"name", "Claude Opus 5.5"}, {"efforts", levels},
                 {"defaultEffort", "medium"}, {"fast", true}},
                QVariantMap{{"id", "claude-sonnet-5-5"}, {"name", "Claude Sonnet 5.5"}, {"efforts", levels},
                    {"defaultEffort", "medium"}, {"fast", false}},
                QVariantMap{{"id", "claude-haiku-4-5"}, {"name", "Claude Haiku 4.5"}, {"efforts", QStringList()}},
                QVariantMap{{"id", "claude-fable-5-1"}, {"name", "Claude Fable 5.1"}, {"efforts", levels},
                    {"defaultEffort", "medium"}, {"fast", false}}});
        return;
    }
    if (provider == "codex") {
        m_codex->call("model/list", {}, [this, provider](const QJsonValue &result, const QString &) {
            QVariantList models;
            for (const auto &value : result.toObject().value("data").toArray()) {
                const auto entry = value.toObject();
                if (entry.value("hidden").toBool()) continue;
                QStringList efforts;
                for (const auto &option : entry.value("supportedReasoningEfforts").toArray())
                    efforts << option.toObject().value("reasoningEffort").toString();
                bool fast = false;
                for (const auto &tier : entry.value("serviceTiers").toArray())
                    fast = fast || tier.toObject().value("id").toString() == "priority";
                models.append(QVariantMap{{"id", entry.value("model").toString(entry.value("id").toString())},
                    {"name", entry.value("displayName").toString(entry.value("model").toString())},
                    {"isDefault", entry.value("isDefault").toBool()}, {"efforts", efforts},
                    {"defaultEffort", entry.value("defaultReasoningEffort").toString()}, {"fast", fast}});
            }
            emit modelsLoaded(provider, models);
        });
        return;
    }
    if (acpAgent(provider)) {
        if (!agentInstalled(provider) || (provider == "claude-agent" && !hasApiKey("claude"))) {
            emit modelsLoaded(provider, {});
            return;
        }
        // Agents report their models as a session option; a throwaway session reads them.
        agentBridge(provider)->call("session/new",
            {{"cwd", agentDirectory(provider) + "/work"}, {"mcpServers", QJsonArray()}},
            [this, provider](const QJsonValue &result, const QJsonObject &) {
                // Effort and fast mode are session options, the same for every model the agent lists.
                const auto session = result.toObject();
                const auto capabilities = AcpProvider::capabilities(session);
                QVariantList models;
                for (auto value : AcpProvider::modelChoices(AcpProvider::modelOption(session))) {
                    auto entry = value.toMap();
                    entry.insert(capabilities);
                    models.append(entry);
                }
                emit modelsLoaded(provider, models);
            });
        return;
    }
    if (provider != "openai" && provider != "ollama") return;
    QNetworkRequest request(provider == "ollama" ? baseUrl(provider).resolved(QUrl("api/tags"))
                                                 : baseUrl(provider).resolved(QUrl("v1/models")));
    if (provider == "openai") {
        const auto key = Keychain::read(keyAccount(provider), m_store->dataDirectory());
        if (key.isEmpty()) {
            emit modelsLoaded(provider, {});
            return;
        }
        request.setRawHeader("Authorization", "Bearer " + key.toUtf8());
    }
    request.setTransferTimeout(10000);
    auto *reply = m_network->get(request);
    connect(reply, &QNetworkReply::finished, this, [this, reply, provider] {
        reply->deleteLater();
        const auto json = QJsonDocument::fromJson(reply->readAll()).object();
        QVariantList models;
        // Chat models only; embeddings, audio, image and moderation models cannot answer here.
        static const QRegularExpression other(
            "embed|whisper|tts|audio|dall-e|image|moderation|realtime|transcribe|search");
        for (const auto &value : json.value(provider == "ollama" ? "models" : "data").toArray()) {
            const auto id = value.toObject().value(provider == "ollama" ? "name" : "id").toString();
            if (id.isEmpty()
                || (provider == "openai" && (id.contains(other) || !(id.startsWith("gpt") || id.startsWith('o')))))
                continue;
            // OpenAI reasoning models take reasoning.effort; every model can use the priority tier.
            const bool reasoning
                = provider == "openai" && (id.startsWith("gpt-5") || id.startsWith("gpt-6") || id.startsWith('o'));
            models.append(QVariantMap{{"id", id}, {"name", id},
                {"efforts", reasoning ? QStringList{"low", "medium", "high"} : QStringList()},
                {"defaultEffort", reasoning ? "medium" : ""}, {"fast", provider == "openai"}});
        }
        std::sort(models.begin(), models.end(), [](const QVariant &a, const QVariant &b) {
            return a.toMap().value("id").toString() > b.toMap().value("id").toString();
        });
        emit modelsLoaded(provider, models);
    });
}

// --- ACP agents -------------------------------------------------------------------------------

QString AiService::agentDirectory(const QString &id) const
{
    return m_store->dataDirectory() + "/agents/" + id;
}

QString AiService::agentExecutable(const QString &id) const
{
    // Tests run a stand-in agent.
    const auto override = qEnvironmentVariable("OWELK_ACP_COMMAND");
    if (!override.isEmpty()) return override;
    const auto *agent = acpAgent(id);
    return agent ? agentDirectory(id) + "/node_modules/.bin/" + agent->bin : QString();
}

bool AiService::agentInstalled(const QString &id) const
{
    return acpAgent(id) && QFileInfo(agentExecutable(id)).isExecutable();
}

QVariantList AiService::agents() const
{
    QVariantList rows;
    for (const auto &agent : acpAgents())
        rows.append(QVariantMap{{"id", agent.id}, {"name", agent.name}, {"package", agent.package},
            {"installed", agentInstalled(agent.id)},
            {"installing", m_installing && m_installing->objectName() == agent.id},
            {"npm", !npmExecutable().isEmpty()}});
    return rows;
}

AcpBridge *AiService::agentBridge(const QString &id)
{
    const auto key = id == "claude-agent" ? Keychain::read(keyAccount("claude"), m_store->dataDirectory()) : QString();
    // A changed key needs a new process, since the agent reads it at start.
    if (auto *bridge = m_agents.value(id); bridge && m_agentKeys.value(id) == key) return bridge;
    delete m_agents.take(id);
    const auto *agent = acpAgent(id);
    auto environment = QProcessEnvironment::systemEnvironment();
    const auto node = findTool("node");
    if (!node.isEmpty())
        environment.insert("PATH", QFileInfo(node).absolutePath() + ":" + environment.value("PATH", "/usr/bin:/bin"));
    if (id == "claude-agent") {
        // Only the API key pays: no claude.ai subscription token, and a private config folder so the
        // agent never picks up a Claude Code login from ~/.claude.
        for (const auto *name : {"CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_AUTH_TOKEN"}) environment.remove(name);
        environment.insert("ANTHROPIC_API_KEY", key);
        environment.insert("CLAUDE_CONFIG_DIR", agentDirectory(id) + "/config");
        QDir().mkpath(agentDirectory(id) + "/config");
    }
    // An empty working folder: the agent has no project files to look at.
    QDir().mkpath(agentDirectory(id) + "/work");
    auto *bridge = new AcpBridge(
        agentExecutable(id), agent ? agent->args : QStringList(), environment, agentDirectory(id) + "/work", this);
    m_agents.insert(id, bridge);
    m_agentKeys.insert(id, key);
    return bridge;
}

bool AiService::installAgent(const QString &id)
{
    const auto *agent = acpAgent(id);
    const auto npm = npmExecutable();
    if (!agent || m_installing) return false;
    if (npm.isEmpty()) {
        emit agentInstallFinished(id, false,
            "Node.js is needed to install agents. Install it from nodejs.org or with Homebrew (brew install node).");
        return false;
    }
    delete m_agents.take(id);
    QDir().mkpath(agentDirectory(id));
    auto *process = new QProcess(this);
    process->setObjectName(id);
    auto environment = QProcessEnvironment::systemEnvironment();
    environment.insert("PATH", QFileInfo(npm).absolutePath() + ":" + environment.value("PATH", "/usr/bin:/bin"));
    process->setProcessEnvironment(environment);
    process->setProcessChannelMode(QProcess::MergedChannels);
    m_installing = process;
    connect(process, &QProcess::finished, this, [this, process, id](int code, QProcess::ExitStatus status) {
        process->deleteLater();
        m_installing = nullptr;
        const bool ok = status == QProcess::NormalExit && code == 0 && agentInstalled(id);
        const auto output = QString::fromUtf8(process->readAll()).trimmed().right(400);
        emit agentInstallFinished(id, ok, ok ? QStringLiteral("Installed.") : "Install failed: " + output);
        emit providersChanged();
    });
    connect(process, &QProcess::errorOccurred, this, [this, process, id](QProcess::ProcessError error) {
        if (error != QProcess::FailedToStart) return;
        process->deleteLater();
        m_installing = nullptr;
        emit agentInstallFinished(id, false, "Cannot run npm.");
    });
    process->start(npm,
        {"install", "--prefix", agentDirectory(id), "--no-audit", "--no-fund", QString(agent->package) + "@latest"});
    emit providersChanged();
    return true;
}

bool AiService::removeAgent(const QString &id)
{
    if (!acpAgent(id) || (m_installing && m_installing->objectName() == id)) return false;
    delete m_agents.take(id);
    // Only Owelk's own install folder is removed; the agent's sign-in stays with the agent.
    const bool ok = QDir(agentDirectory(id)).removeRecursively();
    if (provider() == id) setProvider("claude");
    emit providersChanged();
    return ok;
}

void AiService::refreshAgent(const QString &id)
{
    if (!agentInstalled(id)) {
        emit agentStatus(id, {{"installed", false}});
        return;
    }
    // The initialize answer lists how the agent can sign in.
    agentBridge(id)->call("session/new", {{"cwd", agentDirectory(id) + "/work"}, {"mcpServers", QJsonArray()}},
        [this, id](const QJsonValue &, const QJsonObject &error) {
            QVariantList methods;
            for (const auto &value : m_agents.value(id)->agentInfo().value("authMethods").toArray()) {
                const auto method = value.toObject();
                // Terminal sign-in needs a terminal Owelk does not provide.
                if (method.value("type").toString() == "terminal") continue;
                methods.append(
                    QVariantMap{{"id", method.value("id").toString()}, {"name", method.value("name").toString()},
                        {"description", method.value("description").toString()}});
            }
            emit agentStatus(id,
                {{"installed", true}, {"ready", error.isEmpty()}, {"authMethods", methods},
                    {"error", error.isEmpty() ? QString() : AcpProvider::errorText(acpAgent(id)->name, error)}});
        });
}

void AiService::authenticateAgent(const QString &id, const QString &methodId)
{
    if (!agentInstalled(id) || methodId.isEmpty() || id == "claude-agent") return;
    // The agent runs its own sign-in (usually a browser page); Owelk never sees the credentials.
    agentBridge(id)->call(
        "authenticate", {{"methodId", methodId}}, [this, id](const QJsonValue &, const QJsonObject &error) {
            if (!error.isEmpty()) m_store->notify(AcpProvider::errorText(acpAgent(id)->name, error));
            refreshAgent(id);
            emit providersChanged();
        });
}

// --- Attached images ----------------------------------------------------------------------------

QString AiService::attachmentDirectory() const
{
    const auto directory = m_store->dataDirectory() + "/ai-attachments";
    QDir().mkpath(directory);
    return directory;
}

bool AiService::clipboardHasImage() const
{
    const auto *data = QGuiApplication::clipboard()->mimeData();
    return data && data->hasImage();
}

QString AiService::saveClipboardImage()
{
    if (!clipboardHasImage()) return {};
    const auto image = QGuiApplication::clipboard()->image();
    if (image.isNull()) return {};
    const auto path = attachmentDirectory() + "/" + QUuid::createUuid().toString(QUuid::WithoutBraces) + ".png";
    return image.save(path, "PNG") ? QUrl::fromLocalFile(path).toString() : QString();
}
