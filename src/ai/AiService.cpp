#include "PdfAccess.h"
#include "AiService.h"
#include "FileFingerprint.h"
#include "AiContext.h"
#include "AiProviders.h"
#include "Keychain.h"
#include "ResearchStore.h"

#include <QBuffer>
#include <QCryptographicHash>
#include <QJsonObject>
#include <QClipboard>
#include <QMimeData>
#include <QDesktopServices>
#include <QElapsedTimer>
#include <QGuiApplication>
#include <QImage>
#include <QPainter>
#include <QUuid>
#include <QDir>
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
};
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
        rows.append(QVariantMap{{"id", id}, {"name", entry.name}, {"kind", entry.kind}, {"sends", entry.sends},
            {"configured", configured}, {"model", model(id)}, {"defaultModel", entry.defaultModel},
            {"consented", consented(id)}});
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

QString AiService::keyStorage() const
{
    return Keychain::storageName();
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
    // An Explain card keeps its answer in its own cache; a thread starts only from Continue in AI.
    const bool card = spec.value("card").toBool();
    if (!card
        && (spec.value("threadId").toString().isEmpty()
            || m_store->aiThread(spec.value("threadId").toString()).isEmpty())) {
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
        if (spec.value("scope").toString() == "library")
            retrieveLibrary(request, id, spec, next);
        else
            run(request, id, spec, next);
    });
    watcher->setFuture(QtConcurrent::run([pdfSource, scope, page, imagePaths, userImages, attachments] {
        Material material;
        if (pdfSource.isLocalFile() && (scope == "page" || scope == "paper")) {
            QPdfDocument pdf;
            if (PdfAccess::load(pdf, pdfSource.toLocalFile()) != QPdfDocument::Error::None) {
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

void AiService::retrieveLibrary(int request, const QString &id, QVariantMap spec, QVariantMap prepared)
{
    const auto question = spec.value("question").toString().simplified();
    QString error;
    auto *provider = question.isEmpty() ? nullptr : createProvider(id, &error);
    if (!provider) {
        m_running.remove(request);
        emit busyChanged();
        emit failed(request, question.isEmpty() ? QStringLiteral("Type a question for your library.") : error);
        return;
    }
    // Papers are mostly in English while the question may not be: ask for search terms first.
    AiRequest call;
    call.system = "You turn a researcher's question into full-text search terms for their paper library. Reply with "
                  "6 to 12 terms only, comma-separated, in English (and also in the question's language when it is "
                  "not English): key technical words and short phrases, abbreviations spelled both ways.";
    call.text = question;
    call.model = model(id);
    // Room for the thinking that current models always do.
    call.maxTokens = 2000;
    m_running.insert(request, provider);
    connect(provider, &AiProvider::finished, this,
        [this, request, id, spec, prepared, provider, question](const QString &text, const QString &) mutable {
            provider->deleteLater();
            if (!m_running.contains(request)) return; // Stopped.
            QStringList terms;
            for (auto term : text.split(QRegularExpression("[,\\n;]"))) {
                term = term.remove(QRegularExpression("[\"'*`]")).simplified();
                if (term.size() >= 2 && term.size() <= 60 && !terms.contains(term, Qt::CaseInsensitive)) terms << term;
            }
            // The question's own longer words help too (English questions, names, acronyms).
            for (const auto &word : question.split(QRegularExpression("[^\\w-]+"), Qt::SkipEmptyParts))
                if (word.size() >= 4 && !terms.contains(word, Qt::CaseInsensitive)) terms << word;
            const auto collection = spec.value("collection").toString();
            const auto passages = m_store->libraryPassages(terms.mid(0, 20), 8, collection);
            if (passages.isEmpty()) {
                m_running.remove(request);
                emit busyChanged();
                emit failed(request,
                    QString("No passage in %1 matches this question. Only papers whose text is indexed are "
                            "searched; try other words.")
                        .arg(collection.isEmpty() ? "your library" : "this collection"));
                return;
            }
            QStringList blocks;
            QVariantList sources;
            for (const auto &value : passages) {
                const auto p = value.toMap();
                const auto year = p["year"].toString();
                blocks << QStringLiteral("[%1] %2%3, page %4\n%5")
                              .arg(p["n"].toInt())
                              .arg(p["title"].toString(), year.isEmpty() ? QString() : " (" + year + ")")
                              .arg(p["page"].toInt() + 1)
                              .arg(p["excerpt"].toString());
                sources << p;
            }
            prepared.insert("libraryText", blocks.join("\n\n"));
            spec.insert("sources", sources);
            m_running.insert(request, nullptr);
            run(request, id, spec, prepared);
        });
    connect(provider, &AiProvider::failed, this, [this, request, provider](const QString &message) {
        provider->deleteLater();
        if (!m_running.contains(request)) return;
        m_running.remove(request);
        emit busyChanged();
        emit failed(request, message);
    });
    provider->start(call);
}

// "[2]" in a library answer becomes a link to that paper's page, and the sources are listed below it.
// [p. 3: "exact words"] (or [p. 3], [pp. 3-4]) in an answer about one paper: a link that opens the
// paper at that page and lights up the words (DocumentWorkspace.openLink, ResearchStore::revealPassage).
static QString withPageLinks(const QString &answer, const QString &documentId)
{
    static const QRegularExpression cite(
        R"re(\[pp?\.\s*(\d{1,4})(?:\s*[-\x{2013}]\s*\d{1,4})?(?:\s*[:,]\s*["\x{201c}]([^"\x{201d}\]]{3,240})["\x{201d}])?\](?!\())re");
    QString linked;
    qsizetype last = 0;
    for (auto it = cite.globalMatch(answer); it.hasNext();) {
        const auto m = it.next();
        auto link = QStringLiteral("owelk://document/%1#page=%2").arg(documentId, m.captured(1));
        if (!m.captured(2).isEmpty())
            link += "&q=" + QString::fromLatin1(QUrl::toPercentEncoding(m.captured(2).simplified()));
        linked += answer.mid(last, m.capturedStart() - last) + QStringLiteral("[p. %1](%2)").arg(m.captured(1), link);
        last = m.capturedEnd();
    }
    return linked + answer.mid(last);
}

static QString withSourceLinks(const QString &answer, const QVariantList &sources)
{
    QHash<int, QString> links;
    QStringList list;
    for (const auto &value : sources) {
        const auto p = value.toMap();
        const auto link
            = QStringLiteral("owelk://document/%1#page=%2").arg(p["documentId"].toString()).arg(p["page"].toInt() + 1);
        links.insert(p["n"].toInt(), link);
        list << QStringLiteral("- [%1] [%2, p. %3](%4)")
                    .arg(p["n"].toInt())
                    .arg(p["title"].toString())
                    .arg(p["page"].toInt() + 1)
                    .arg(link);
    }
    QString text = answer;
    static const QRegularExpression marker(R"(\[(\d{1,2})\](?!\())");
    QString linked;
    qsizetype last = 0;
    for (auto it = marker.globalMatch(text); it.hasNext();) {
        const auto m = it.next();
        linked += text.mid(last, m.capturedStart() - last);
        const auto link = links.value(m.captured(1).toInt());
        linked += link.isEmpty() ? m.captured() : "[[" + m.captured(1) + "]](" + link + ")";
        last = m.capturedEnd();
    }
    linked += text.mid(last);
    return linked.trimmed() + "\n\n**Sources**\n" + list.join('\n');
}

void AiService::run(int request, const QString &id, const QVariantMap &spec, const QVariantMap &prepared)
{
    const auto threadId = spec.value("threadId").toString();
    QList<AiTurn> history;
    // A fresh turn (a page translation) stands alone: earlier turns are kept in the thread, not resent.
    if (!spec.value("fresh").toBool())
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
    materials.quote = spec.value("quote").toString().left(4000);
    materials.pageText = prepared.value("pageText").toString();
    materials.paperText = prepared.value("paperText").toString();
    materials.libraryText = prepared.value("libraryText").toString();
    materials.notes = prepared.value("notes").toStringList();
    materials.pageNumber = spec.value("scope").toString() == "page" ? spec.value("page").toInt() + 1 : 0;
    if (spec.value("card").toBool() && !spec.value("label").toString().isEmpty())
        materials.label = spec.value("label").toString() + ", page " + QString::number(spec.value("page").toInt() + 1);
    materials.level = spec.value("level").toString().isEmpty() ? m_store->setting("ai.explainLevel", "easy")
                                                               : spec.value("level").toString();
    const auto images = prepared.value("images").toList();
    materials.hasImage = !images.isEmpty();
    const auto action
        = spec.value("scope").toString() == "library" ? QStringLiteral("library") : spec.value("action").toString();
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
    call.context = prompt.context;
    call.text = prompt.text;
    call.model = spec.value("model").toString().isEmpty() ? model(id) : spec.value("model").toString().left(120);
    // Provider level names only (low, medium, xhigh, …); anything else is ignored.
    static const QRegularExpression level("^[a-z_-]{1,16}$");
    const auto effort = spec.value("effort").toString();
    if (level.match(effort).hasMatch()) call.effort = effort;
    call.fast = spec.value("fast").toBool();
    // Reasoning summaries, unless turned off (Settings → AI) or refused by this OpenAI account before.
    call.thinkingSummary = m_store->setting("ai.showThinking", "1") == "1"
        && !(id == "openai" && m_store->setting("ai.reasoningSummary.openai") == "0");
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
    // The summary and the time until the answer began, stored with the answer.
    struct Thought {
        QString text;
        QElapsedTimer clock;
        qint64 untilAnswer = -1;
    };
    auto thought = std::make_shared<Thought>();
    thought->clock.start();
    connect(provider, &AiProvider::thinkingDelta, this, [this, request, thought](const QString &text) {
        thought->text += text;
        emit thinking(request, text);
    });
    connect(provider, &AiProvider::delta, this, [this, request, thought](const QString &text) {
        if (thought->untilAnswer < 0) thought->untilAnswer = thought->clock.elapsed();
        emit delta(request, text);
    });
    // Stores the turn: a whole answer, or what had arrived when the reader stopped it.
    const auto store = [this, request, id, prompt, spec, done, threadId, thought, provider, attached = materials](
                           const QString &answer, const QString &used, bool stopped) {
        done();
        auto text = spec.contains("sources") ? withSourceLinks(answer, spec.value("sources").toList()) : answer;
        // Page citations in an answer about one paper become links to those places.
        if (!spec.contains("sources") && (!attached.pageText.isEmpty() || !attached.paperText.isEmpty())) {
            const auto document = m_store->documentLinkId(spec.value("source").toUrl());
            if (!document.isEmpty()) text = withPageLinks(text, document);
        }
        const auto usedModel = used.isEmpty() ? model(id) : used;
        const auto sent = prompt.context.isEmpty() ? prompt.text : prompt.context + "\n\n" + prompt.text;
        if (spec.value("card").toBool()) {
            finishExplanation(request, spec, sent, text, id, usedModel, stopped);
            return;
        }
        // Question and answer are stored together, so a thread always alternates them.
        static const QHash<QString, QString> labels{{"explain", "Explain"}, {"translate", "Translate"},
            {"summarize", "Summarize"}, {"figure", "Explain figure"}};
        auto display = spec.value("question").toString().trimmed();
        if (display.isEmpty()) display = spec.value("label").toString();
        if (display.isEmpty()) display = labels.value(spec.value("action").toString(), "Ask");
        QStringList attachments;
        if (!attached.selection.isEmpty()) attachments << "selection";
        if (!attached.pageText.isEmpty()) attachments << QStringLiteral("page %1").arg(attached.pageNumber);
        if (!attached.paperText.isEmpty()) attachments << "paper";
        if (attached.hasImage) attachments << "image";
        if (!attached.libraryText.isEmpty()) attachments << "library";
        if (!attached.quote.isEmpty()) attachments << "quote";
        m_store->appendAiMessage(threadId,
            {{"role", "user"}, {"content", sent}, {"display", display}, {"provider", id}, {"model", usedModel},
                {"context",
                    QVariantMap{{"attachments", attachments}, {"captureId", spec.value("captureId")},
                        {"selection", attached.selection.left(400)}, {"quote", attached.quote.left(400)},
                        {"page", spec.value("page")}}}});
        // The reasoning summary sits in the answer's context: shown folded, never copied or resent.
        QVariantMap answerContext;
        const auto reasoning = thought->text.trimmed();
        if (!reasoning.isEmpty()) {
            answerContext.insert("thinking", reasoning);
            const auto ms = thought->untilAnswer >= 0 ? thought->untilAnswer : thought->clock.elapsed();
            answerContext.insert("thinkingSeconds", qMax<qint64>(1, (ms + 500) / 1000));
        }
        const bool cutOff = !stopped && provider->cutOff();
        if (cutOff) answerContext.insert("cutOff", true);
        if (stopped) answerContext.insert("stopped", true);
        m_store->appendAiMessage(threadId,
            {{"role", "assistant"}, {"content", text}, {"model", usedModel}, {"provider", id},
                {"context", answerContext}});
        emit finished(request, text,
            {{"provider", id}, {"model", usedModel}, {"prompt", sent}, {"threadId", threadId},
                {"action", spec.value("action")}, {"question", spec.value("question")},
                {"source", spec.value("source")}, {"page", spec.value("page")}, {"captureId", spec.value("captureId")},
                {"cutOff", cutOff}, {"stopped", stopped}});
    };
    connect(provider, &AiProvider::finished, this,
        [store](const QString &answer, const QString &used) { store(answer, used, false); });
    connect(provider, &AiProvider::failed, this,
        [this, request, done, store, provider, id, spec, prepared, summary = call.thinkingSummary](
            const QString &message) {
            // Stopped part-way: the text so far is kept as the answer, with Copy and Save as Note.
            if (message == "Stopped." && !provider->partialText().trimmed().isEmpty()) {
                store(provider->partialText(), QString(), true);
                return;
            }
            done();
            // Some OpenAI accounts may not receive reasoning summaries: ask again without, and remember.
            if (summary && id == "openai"
                && (message.contains("summar", Qt::CaseInsensitive)
                    || message.contains("verif", Qt::CaseInsensitive))) {
                m_store->setSetting("ai.reasoningSummary.openai", "0");
                run(request, id, spec, prepared);
                return;
            }
            emit failed(request, message);
        });
    emit started(request, threadId, id, call.model, prompt.truncated);
    provider->start(call);
}

QString AiService::explanationKey(const QVariantMap &spec) const
{
    const auto url = m_store->resolvedSource(spec.value("source").toUrl());
    const auto paper = url.isLocalFile() ? FileFingerprint::sha256(url.toLocalFile()) : url.toString();
    const auto kind = spec.value("kind").toString();
    const auto region = spec.value("region").toRectF();
    QStringList parts{paper, kind, m_store->setting("aiLanguage", "ko")};
    if (kind != "notation") {
        parts << spec.value("level").toString() << QString::number(spec.value("page").toInt());
        // Rounded, so the same figure found again (or from its preview) is the same explanation.
        parts << QStringLiteral("%1,%2,%3,%4")
                     .arg(qRound(region.x() * 200))
                     .arg(qRound(region.y() * 200))
                     .arg(qRound(region.width() * 200))
                     .arg(qRound(region.height() * 200));
        parts << spec.value("selection").toString().simplified();
    }
    return QString::fromLatin1(QCryptographicHash::hash(parts.join('\n').toUtf8(), QCryptographicHash::Sha1).toHex());
}

QVariantMap AiService::explanation(const QString &key) const
{
    static const QRegularExpression plain("^[0-9a-f]{40}$");
    if (!plain.match(key).hasMatch()) return {};
    QFile file(m_store->dataDirectory() + "/ai-explanations/" + key + ".json");
    if (!file.open(QIODevice::ReadOnly)) return {};
    return QJsonDocument::fromJson(file.readAll()).object().toVariantMap();
}

bool AiService::keepExplanation(const QVariantMap &entry) const
{
    const auto folder = m_store->dataDirectory() + "/ai-explanations";
    QFile file(folder + "/" + entry.value("key").toString() + ".json");
    return QDir().mkpath(folder) && file.open(QIODevice::WriteOnly)
        && file.write(QJsonDocument(QJsonObject::fromVariantMap(entry)).toJson(QJsonDocument::Compact)) > 0;
}

int AiService::explain(const QVariantMap &input)
{
    auto spec = input;
    const auto kind = spec.value("kind").toString();
    static const QHash<QString, QString> actions{{"figure", "figure"}, {"table", "figure"}, {"algorithm", "algorithm"},
        {"equation", "equation"}, {"selection", "explain"}, {"notation", "notation"}};
    if (!actions.contains(kind)) {
        const int request = ++m_nextRequest;
        QMetaObject::invokeMethod(
            this, [this, request] { emit failed(request, "Nothing to explain here."); }, Qt::QueuedConnection);
        return request;
    }
    const auto level = spec.value("level").toString();
    if (level != "easy" && level != "brief") spec.insert("level", m_store->setting("ai.explainLevel", "easy"));
    const auto key = explanationKey(spec);
    const auto kept = spec.value("refresh").toBool() ? QVariantMap() : explanation(key);
    if (!kept.isEmpty()) {
        // Opened before: the kept answer, at once and without a request.
        const int request = ++m_nextRequest;
        QMetaObject::invokeMethod(
            this,
            [this, request, kept] {
                emit started(request, {}, kept.value("provider").toString(), kept.value("model").toString(), false);
                emit finished(request, kept.value("answer").toString(),
                    {{"key", kept.value("key")}, {"cached", true}, {"image", kept.value("image")},
                        {"provider", kept.value("provider")}, {"model", kept.value("model")}});
            },
            Qt::QueuedConnection);
        return request;
    }
    spec.insert("key", key);
    spec.insert("card", true);
    spec.insert("action", actions.value(kind));
    spec.insert("scope", "paper");
    spec.remove("threadId");
    if (kind != "selection" && kind != "notation") {
        // The object itself as an image: equations and drawings do not survive as text.
        const auto image
            = saveRegionImage(spec.value("source").toUrl(), spec.value("page").toInt(), spec.value("region").toRectF());
        if (image.isEmpty()) {
            const int request = ++m_nextRequest;
            QMetaObject::invokeMethod(
                this, [this, request] { emit failed(request, "Could not read this part of the PDF."); },
                Qt::QueuedConnection);
            return request;
        }
        spec.insert("image", image);
        spec.insert("imageFiles", QVariantList{image});
        // A caption's own words help; an equation's extracted text is a jumble.
        if (kind != "equation") spec.insert("selection", spec.value("caption").toString().left(1500));
    }
    return ask(spec);
}

namespace {
// The symbol list in a notation answer: {"symbols": [...]}, maybe wrapped in prose or a code fence.
QVariantList parseSymbols(const QString &answer)
{
    const auto start = answer.indexOf('{'), end = answer.lastIndexOf('}');
    if (start < 0 || end <= start) return {};
    QVariantList symbols;
    for (const auto &value :
        QJsonDocument::fromJson(answer.mid(start, end - start + 1).toUtf8()).object().value("symbols").toArray()) {
        const auto entry = value.toObject();
        const auto symbol = entry.value("symbol").toString().trimmed().left(120);
        const auto meaning = entry.value("meaning").toString().simplified().left(300);
        if (symbol.isEmpty() || meaning.isEmpty()) continue;
        QStringList text;
        const auto printed = entry.value("text");
        for (const auto &form : printed.isArray() ? printed.toArray() : QJsonArray{printed})
            if (!form.toString().trimmed().isEmpty()) text << form.toString().simplified().left(40);
        const int page = entry.value("background").toBool() ? 0 : std::max(0, entry.value("page").toInt());
        symbols.append(QVariantMap{{"symbol", symbol}, {"text", text}, {"meaning", meaning}, {"page", page}});
        if (symbols.size() >= 120) break;
    }
    return symbols;
}

// The symbol list as a Markdown table with links to where each symbol is defined.
QString symbolTable(const QVariantList &symbols, const QString &documentId)
{
    QStringList rows{"| Symbol | Meaning | Where |", "|---|---|---|"};
    for (const auto &value : symbols) {
        const auto entry = value.toMap();
        const int page = entry.value("page").toInt();
        const auto where = page <= 0 ? QStringLiteral("Background")
            : documentId.isEmpty()   ? QStringLiteral("p. %1").arg(page)
                                     : QStringLiteral("[p. %1](owelk://document/%2#page=%1)").arg(page).arg(documentId);
        rows << QStringLiteral("| $%1$ | %2 | %3 |")
                    .arg(entry.value("symbol").toString().replace('|', "\\vert "),
                        entry.value("meaning").toString().replace('|', "/"), where);
    }
    return rows.join('\n');
}
} // namespace

void AiService::finishExplanation(int request, const QVariantMap &spec, const QString &sent, const QString &answer,
    const QString &provider, const QString &model, bool stopped)
{
    const auto kind = spec.value("kind").toString();
    const auto source = spec.value("source").toUrl();
    auto text = answer;
    QVariantList symbols;
    if (kind == "notation") {
        symbols = parseSymbols(answer);
        if (symbols.isEmpty()) {
            emit failed(
                request, stopped ? QStringLiteral("Stopped.") : QStringLiteral("No symbol list came back. Try again."));
            return;
        }
        text = symbolTable(symbols, m_store->documentLinkId(source));
    }
    const auto key = spec.value("key").toString();
    // A stopped answer is shown but not kept: opening it again asks again.
    if (!stopped)
        keepExplanation({{"key", key}, {"kind", kind}, {"label", spec.value("label")}, {"source", source.toString()},
            {"page", spec.value("page")}, {"level", spec.value("level")}, {"prompt", sent}, {"answer", text},
            {"symbols", symbols}, {"provider", provider}, {"model", model}, {"image", spec.value("image")},
            {"created", QDateTime::currentDateTimeUtc().toString(Qt::ISODate)}});
    if (kind == "notation" && !stopped) emit notationChanged(source);
    emit finished(request, text,
        {{"key", key}, {"cached", false}, {"image", spec.value("image")}, {"provider", provider}, {"model", model},
            {"stopped", stopped}});
}

QString AiService::continueExplanation(const QString &key)
{
    auto entry = explanation(key);
    if (entry.isEmpty()) return {};
    const auto existing = entry.value("threadId").toString();
    if (!existing.isEmpty() && !m_store->aiThread(existing).isEmpty()) return existing;
    const QUrl source(entry.value("source").toString());
    const auto kind = entry.value("kind").toString();
    auto label = entry.value("label").toString();
    if (kind == "notation") label = "Symbols";
    if (label.isEmpty()) label = "Selection";
    const auto provider = entry.value("provider").toString(), usedModel = entry.value("model").toString();
    const auto thread = m_store->createAiThread({{"title", "Explain " + label + " · " + m_store->displayName(source)},
        {"provider", provider}, {"model", usedModel}, {"source", source}});
    if (thread.isEmpty()) return {};
    QStringList attachments{"paper"};
    if (!entry.value("image").toString().isEmpty()) attachments << "image";
    m_store->appendAiMessage(thread,
        {{"role", "user"}, {"content", entry.value("prompt")}, {"display", "Explain " + label}, {"provider", provider},
            {"model", usedModel},
            {"context", QVariantMap{{"attachments", attachments}, {"page", entry.value("page")}}}});
    m_store->appendAiMessage(thread,
        {{"role", "assistant"}, {"content", entry.value("answer")}, {"provider", provider}, {"model", usedModel},
            {"context", QVariantMap()}});
    entry.insert("threadId", thread);
    keepExplanation(entry);
    return thread;
}

QVariantList AiService::notation(const QUrl &source)
{
    if (source.isEmpty()) return {};
    auto symbols = explanation(explanationKey({{"source", source}, {"kind", "notation"}})).value("symbols").toList();
    // How each symbol may be printed, as plain forms (math letters as plain ones, no spaces), to match
    // the word under the pointer (ReferenceFinder::wordAt).
    for (auto &value : symbols) {
        auto entry = value.toMap();
        QStringList match;
        for (const auto &form : entry.value("text").toStringList()) {
            const auto plain = form.normalized(QString::NormalizationForm_KC).remove(QRegularExpression("\\s"));
            if (!plain.isEmpty() && !match.contains(plain)) match << plain;
        }
        entry.insert("match", match);
        value = entry;
    }
    return symbols;
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

// Items are named t1…tN (tabs) or p1…pN (papers) in the prompt: short, and no paths or URLs needed in the answer.
static QVariantList parseGroups(
    const QString &answer, const QHash<QString, QString> &ids, const QString &memberKey, const QString &idsKey)
{
    const auto start = answer.indexOf('{'), end = answer.lastIndexOf('}');
    if (start < 0 || end <= start) return {};
    const auto groups
        = QJsonDocument::fromJson(answer.mid(start, end - start + 1).toUtf8()).object().value("groups").toArray();
    QSet<QString> used;
    QVariantList result;
    for (const auto &value : groups) {
        const auto entry = value.toObject();
        const auto name = entry.value("name").toString().simplified().left(80);
        QStringList members;
        for (const auto &member : entry.value(memberKey).toArray()) {
            const auto id = ids.value(member.toString());
            // Unknown names are ignored; an item joins only the first group that claims it.
            if (!id.isEmpty() && !used.contains(id)) {
                members << id;
                used.insert(id);
            }
        }
        if (!name.isEmpty() && !members.isEmpty()) result.append(QVariantMap{{"name", name}, {idsKey, members}});
    }
    return result;
}

static QString describeItem(const QString &name, const QVariantMap &item)
{
    QStringList parts{name + ": " + item.value("title").toString().left(200)};
    if (!item.value("authors").toString().isEmpty() || !item.value("year").toString().isEmpty())
        parts << "  by " + item.value("authors").toString().left(120) + " " + item.value("year").toString();
    if (!item.value("url").toString().isEmpty()) parts << "  address: " + item.value("url").toString().left(200);
    if (!item.value("opening").toString().isEmpty()) parts << "  begins: " + item.value("opening").toString().left(400);
    return parts.join('\n');
}

int AiService::suggestGroups(const QVariantList &items, const QString &prefix, const QString &memberKey,
    const QString &idsKey, const QString &system, const QString &text, GroupReply reply)
{
    const int request = ++m_nextRequest;
    const auto id = provider();
    QString error;
    auto *provider = items.size() < 2 ? nullptr : createProvider(id, &error);
    if (!provider) {
        if (error.isEmpty())
            error = prefix == "t" ? "Open at least two tabs to organize." : "Choose at least two papers.";
        QMetaObject::invokeMethod(
            this, [this, request, error, reply] { emit(this->*reply)(request, {}, error); }, Qt::QueuedConnection);
        return request;
    }
    QHash<QString, QString> ids;
    QStringList lines;
    for (qsizetype i = 0; i < items.size() && i < 80; ++i) {
        const auto item = items[i].toMap();
        const auto name = prefix + QString::number(i + 1);
        ids.insert(name, item.value("id").toString());
        lines << describeItem(name, item);
    }
    AiRequest call;
    call.system = system;
    call.text = text + "\n\n" + lines.join("\n\n");
    call.model = model(id);
    call.maxTokens = 8000;
    m_running.insert(request, provider);
    emit busyChanged();
    const auto done = [this, request, provider] {
        m_running.remove(request);
        provider->deleteLater();
        emit busyChanged();
    };
    connect(provider, &AiProvider::finished, this,
        [this, request, ids, done, memberKey, idsKey, reply](const QString &answer, const QString &) {
            done();
            const auto groups = parseGroups(answer, ids, memberKey, idsKey);
            emit(this->*reply)(
                request, groups, groups.isEmpty() ? QStringLiteral("No groups were suggested.") : QString());
        });
    connect(provider, &AiProvider::failed, this, [this, request, done, reply](const QString &message) {
        done();
        emit(this->*reply)(request, {}, message);
    });
    provider->start(call);
    return request;
}

int AiService::organizeTabs(const QVariantList &tabs)
{
    return suggestGroups(tabs, "t", "tabs", "tabIds",
        "You organize a researcher's open tabs into a few named groups by topic. Use short, specific group "
        "names (2-5 words) in the language of the tab titles. Leave a tab out when it fits no group. Reply "
        "with JSON only: {\"groups\": [{\"name\": \"…\", \"tabs\": [\"t1\", \"t2\"]}]}.",
        "Group these tabs:", &AiService::tabsOrganized);
}

int AiService::organizePapers(const QVariantList &papers, const QStringList &collections)
{
    QString text = "Group these papers:";
    if (!collections.isEmpty()) {
        QStringList names;
        for (const auto &name : collections.mid(0, 60)) names << "- " + name.left(80);
        text = "Collections that already exist:\n" + names.join('\n') + "\n\n" + text;
    }
    return suggestGroups(papers, "p", "papers", "paperIds",
        "You sort a researcher's papers into a few topic collections. Use short, specific names (2-5 words) "
        "in the language of the paper titles. When papers fit a collection that already exists, use its exact "
        "name. Leave a paper out when it fits no group, and do not make a group for a single paper unless it "
        "fits an existing collection. Reply with JSON only: "
        "{\"groups\": [{\"name\": \"…\", \"papers\": [\"p1\", \"p2\"]}]}.",
        text, &AiService::papersOrganized);
}

int AiService::comparePapers(const QVariantList &papers, const QStringList &aspects)
{
    const int request = ++m_nextRequest;
    const auto id = provider();
    QString error;
    auto *provider = papers.size() < 2 ? nullptr : createProvider(id, &error);
    if (!provider) {
        if (error.isEmpty()) error = "Choose at least two papers to compare.";
        QMetaObject::invokeMethod(
            this, [this, request, error] { emit papersCompared(request, {}, error); }, Qt::QueuedConnection);
        return request;
    }
    QStringList parts;
    for (qsizetype i = 0; i < papers.size() && i < 8; ++i) {
        const auto paper = papers[i].toMap();
        QStringList lines{"Title: " + paper.value("title").toString().left(300)};
        if (!paper.value("authors").toString().isEmpty())
            lines << "Authors: " + paper.value("authors").toString().left(200);
        if (!paper.value("year").toString().isEmpty()) lines << "Year: " + paper.value("year").toString();
        lines << "Beginning:\n" + paper.value("opening").toString().left(5000);
        if (!paper.value("closing").toString().isEmpty())
            lines << "Conclusion:\n" + paper.value("closing").toString().left(2500);
        parts << QString("<paper n=\"%1\">\n%2\n</paper>").arg(i + 1).arg(lines.join('\n'));
    }
    QStringList columns;
    for (const auto &aspect : aspects)
        if (!aspect.trimmed().isEmpty()) columns << aspect.trimmed().left(60);
    if (columns.isEmpty()) columns = QStringList{"Problem", "Method", "Data", "Results", "Limitations"};
    const auto language = aiLanguageName(m_store->setting("aiLanguage", "ko"));
    AiRequest call;
    call.system
        = QStringLiteral(
              "You compare research papers for a researcher, using only the text given for each paper. Write a "
              "Markdown "
              "table with one row per paper, in the order given: the first column names the paper (a short title and "
              "the year), then one column per requested aspect. Keep each cell short (at most about 25 words) and "
              "exact about numbers, datasets and terms; write \"not stated\" when the given text does not say. After "
              "the "
              "table, add 3-5 bullet points on the main differences and when each paper is the better choice. Output "
              "only the table and the bullets.")
        + (language.isEmpty()
                ? QStringLiteral(" Write in the language of the papers.")
                : QStringLiteral(" Write in %1; keep technical terms in their original form.").arg(language));
    call.text = "Aspects: " + columns.join(", ") + "\n\n" + parts.join("\n\n");
    call.model = model(id);
    call.maxTokens = 16000;
    m_running.insert(request, provider);
    emit busyChanged();
    const auto done = [this, request, provider] {
        m_running.remove(request);
        provider->deleteLater();
        emit busyChanged();
    };
    connect(provider, &AiProvider::delta, this,
        [this, request](const QString &text) { emit comparisonDelta(request, text); });
    connect(provider, &AiProvider::finished, this, [this, request, done](const QString &text, const QString &) {
        done();
        emit papersCompared(
            request, text.trimmed(), text.trimmed().isEmpty() ? QStringLiteral("No comparison came back.") : QString());
    });
    connect(provider, &AiProvider::failed, this, [this, request, done](const QString &message) {
        done();
        emit papersCompared(request, {}, message);
    });
    provider->start(call);
    return request;
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
    // A small limit would go to thinking before the answer.
    call.maxTokens = 512;
    provider->start(call);
}

void AiService::refreshCodexAccount()
{
    m_codex->call("account/read", {}, [this](const QJsonValue &result, const QString &error) {
        const auto account = result.toObject().value("account").toObject();
        QVariantMap next{{"available", error.isEmpty() || !error.contains("Codex")}, {"error", error},
            {"signedIn", account.value("type").toString() == "chatgpt" || account.value("type").toString() == "apiKey"},
            {"email", account.value("email").toString()}, {"plan", account.value("planType").toString()}};
        if (!error.isEmpty()) next.insert("available", false);
        emit codexAccountChanged(next);
        // Only a real change updates the provider list: listeners that re-read the account
        // when providers change must not loop.
        if (next == m_codexAccount) return;
        m_codexAccount = next;
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

QString AiService::saveRegionImage(const QUrl &source, int page, const QRectF &region)
{
    const auto url = m_store->resolvedSource(source);
    const auto area = region.intersected(QRectF(0, 0, 1, 1));
    if (!url.isLocalFile() || area.isEmpty()) return {};
    QPdfDocument pdf;
    if (PdfAccess::load(pdf, url.toLocalFile()) != QPdfDocument::Error::None || page < 0 || page >= pdf.pageCount())
        return {};
    // About 1600 pixels across the region (the size the providers read best), at most 4x the page.
    const auto points = pdf.pagePointSize(page);
    const qreal scale = std::clamp(1600.0 / std::max(1.0, area.width() * points.width()), 1.0, 4.0);
    const QSize size(qRound(points.width() * scale), qRound(points.height() * scale));
    const auto rendered = pdf.render(page, size);
    if (rendered.isNull()) return {};
    QImage paper(rendered.size(), QImage::Format_RGB32);
    paper.fill(Qt::white); // Pages may be transparent where nothing is printed.
    {
        QPainter painter(&paper);
        painter.drawImage(0, 0, rendered);
    }
    const QRect crop(qRound(area.x() * size.width()), qRound(area.y() * size.height()),
        qRound(area.width() * size.width()), qRound(area.height() * size.height()));
    const auto path = attachmentDirectory() + "/figure-p" + QString::number(page + 1) + "-"
        + QUuid::createUuid().toString(QUuid::WithoutBraces).left(8) + ".png";
    return paper.copy(crop).save(path, "PNG") ? QUrl::fromLocalFile(path).toString() : QString();
}

QString AiService::saveClipboardImage()
{
    if (!clipboardHasImage()) return {};
    const auto image = QGuiApplication::clipboard()->image();
    if (image.isNull()) return {};
    const auto path = attachmentDirectory() + "/" + QUuid::createUuid().toString(QUuid::WithoutBraces) + ".png";
    return image.save(path, "PNG") ? QUrl::fromLocalFile(path).toString() : QString();
}
