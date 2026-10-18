#include "ReferenceFinder.h"
#include "PdfAccess.h"
#include <QPdfDocument>
#include <QPdfLinkModel>
#include <QPdfSelection>
#include <QRegularExpression>
#include <QSet>

namespace {
QRegularExpression referencesHeading()
{
    return QRegularExpression(
        R"((?:^|[\r\n])[ \t]*(?:[IVX\d]+\.?[ \t]*)?(?:References|R EFERENCES|Bibliography|Literature Cited)[ \t]*(?=[\r\n]|$))",
        QRegularExpression::CaseInsensitiveOption);
}
QString repository(const QString &input)
{
    QString value = input;
    while (!value.isEmpty() && QString(".,;:!?)]}>").contains(value.back())) value.chop(1);
    if (!value.contains("://")) value.prepend("https://");
    const QUrl url(value);
    if (url.scheme() != "https" && url.scheme() != "http") return {};
    QString host = url.host().toLower();
    if (host.startsWith("www.")) host.remove(0, 4);
    if (host != "github.com" && host != "gitlab.com" && host != "huggingface.co") return {};
    if (!url.userInfo().isEmpty() || url.port() != -1) return {};
    auto parts = url.path().split('/', Qt::SkipEmptyParts);
    int count = 2;
    if (host == "huggingface.co" && !parts.isEmpty() && (parts[0] == "spaces" || parts[0] == "datasets")) count = 3;
    if (parts.size() < count) return {};
    const QSet<QString> excluded{"about", "blog", "docs", "explore", "features", "topics", "collections", "settings",
        "users", "orgs", "login", "join", "search", "pricing", "site", "help", "organizations"};
    if (excluded.contains(parts[0].toLower())) return {};
    if (parts[count - 1].endsWith(".git", Qt::CaseInsensitive)) parts[count - 1].chop(4);
    static const QRegularExpression segment("^[A-Za-z0-9_][A-Za-z0-9_.-]*$");
    for (int i = 0; i < count; ++i)
        if (!segment.match(parts[i]).hasMatch()) return {};
    return "https://" + host + "/" + parts.mid(0, count).join('/');
}
}

QStringList ReferenceFinder::repositoryLinks(const QStringList &pages, const QVariantList &annotations)
{
    QStringList found;
    QSet<QString> seen;
    const auto add = [&](const QString &value) {
        const auto url = repository(value);
        if (!url.isEmpty() && !seen.contains(url.toLower()) && found.size() < 3) {
            seen.insert(url.toLower());
            found << url;
        }
    };
    static const QRegularExpression link(
        R"((?<![\w./@-])(?:https?://)?(?:www\.)?(?:github\.com|gitlab\.com|huggingface\.co)/[^\s<>"']+)",
        QRegularExpression::CaseInsensitiveOption);
    for (int page = 0; page < pages.size() && found.size() < 3; ++page) {
        const auto heading = referencesHeading().match(pages[page]);
        const auto body = heading.hasMatch() ? pages[page].left(heading.capturedStart()) : pages[page];
        for (auto it = link.globalMatch(body); it.hasNext();) add(it.next().captured());
        for (const auto &entry : annotations) {
            const auto item = entry.toMap();
            if (item.value("page").toInt() == page && item.value("body").toBool()) add(item.value("url").toString());
        }
        if (heading.hasMatch()) break;
    }
    return found;
}

int ReferenceFinder::codeLinks(const QUrl &source)
{
    const int request = ++m_next;
    const auto path = source.toLocalFile();
    m_pool.start([this, request, path] {
        QStringList found, pages;
        QVariantList annotations;
        QPdfDocument pdf;
        if (!path.isEmpty() && PdfAccess::load(pdf, path) == QPdfDocument::Error::None) {
            QPdfLinkModel links;
            links.setDocument(&pdf);
            for (int page = 0; page < pdf.pageCount() && m_latest != INT_MAX; ++page) {
                const auto text = pdf.getAllText(page).text();
                pages << text;
                const auto heading = referencesHeading().match(text);
                qreal before = pdf.pagePointSize(page).height();
                if (heading.hasMatch()) {
                    before = 0;
                    const auto boxes
                        = pdf.getSelectionAtIndex(page, heading.capturedStart(), heading.capturedLength()).bounds();
                    if (!boxes.isEmpty()) before = boxes.first().boundingRect().top();
                }
                links.setPage(page);
                for (int row = 0; row < links.rowCount({}); ++row) {
                    const auto index = links.index(row, 0);
                    const auto box = links.data(index, int(QPdfLinkModel::Role::Rectangle)).toRectF();
                    annotations << QVariantMap{{"page", page},
                        {"url", links.data(index, int(QPdfLinkModel::Role::Url)).toUrl().toString()},
                        {"body", box.bottom() < before}};
                }
                if (heading.hasMatch()) break;
            }
            found = repositoryLinks(pages, annotations);
        }
        QMetaObject::invokeMethod(
            this, [this, request, found] { emit codeLinksFound(request, found); }, Qt::QueuedConnection);
    });
    return request;
}
