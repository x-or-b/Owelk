#include "PaperMetadata.h"
#include "SelectionGeometry.h"

#include <QDate>
#include <QDateTime>
#include <QFileInfo>
#include <QPdfDocument>
#include <QPdfSelection>
#include <QRegularExpression>
#include <algorithm>

namespace PaperMetadataText {
bool usableTitle(const QString &input, const QString &fileName)
{
    const auto title = input.simplified();
    const auto lower = title.toLower();
    if (title.size() < 4 || title.size() > 300) return false;
    static const QRegularExpression fileLike("\\.(pdf|docx?|tex|dvi|ps|indd|qxd)$");
    static const QRegularExpression pathLike("^(/|[a-z]:\\\\)");
    if (lower.contains(fileLike) || lower.contains(pathLike)) return false;
    // Producer defaults rather than a paper title.
    for (const auto *prefix : {"microsoft word -", "microsoft powerpoint -", "untitled", "arxiv:", "doi:", "pii:"})
        if (lower.startsWith(QLatin1String(prefix))) return false;
    static const QRegularExpression placeholder(
        "^(title|paper|manuscript|document|slides|presentation|main|draft)[\\s_\\-\\d]*$");
    if (lower.contains(placeholder)) return false;
    if (lower == QFileInfo(fileName).completeBaseName().toLower()) return false;
    return std::count_if(title.cbegin(), title.cend(), [](QChar c) { return c.isLetter(); }) >= 4;
}

QString findDoi(const QString &text)
{
    static const QRegularExpression doi("\\b(10\\.\\d{4,9}/[^\\s\"<>]+)", QRegularExpression::CaseInsensitiveOption);
    auto value = doi.match(text).captured(1);
    while (!value.isEmpty() && QStringLiteral(".,;:)]}'").contains(value.back())) value.chop(1);
    return value;
}

QString findArxiv(const QString &text)
{
    static const QRegularExpression modern(
        "arXiv\\s*:\\s*(\\d{4}\\.\\d{4,5})(v\\d+)?", QRegularExpression::CaseInsensitiveOption);
    static const QRegularExpression legacy(
        "arXiv\\s*:\\s*([a-z\\-]+(\\.[A-Z]{2})?/\\d{7})(v\\d+)?", QRegularExpression::CaseInsensitiveOption);
    const auto match = modern.match(text);
    if (match.hasMatch()) return match.captured(1);
    return legacy.match(text).captured(1);
}
}

namespace {
QString arxivFromFileName(const QString &fileName)
{
    static const QRegularExpression name("^(\\d{4}\\.\\d{4,5})(v\\d+)?$");
    return name.match(QFileInfo(fileName).completeBaseName()).captured(1);
}

QString yearFromArxiv(const QString &id)
{
    static const QRegularExpression modern("^(\\d{2})(\\d{2})\\.");
    const auto match = modern.match(id);
    if (!match.hasMatch()) return {};
    const int year = 2000 + match.captured(1).toInt(), month = match.captured(2).toInt();
    return year >= 2007 && year <= QDate::currentDate().year() && month >= 1 && month <= 12 ? QString::number(year)
                                                                                            : QString();
}

QString cleanAuthors(const QString &input)
{
    auto authors = input.simplified();
    const auto lower = authors.toLower();
    // Account names and placeholders are not authors.
    if (authors.size() < 3 || authors.size() > 500 || authors.contains('@')
        || QStringList{"author", "authors", "unknown", "user", "admin", "administrator", "owner"}.contains(lower)
        || (!authors.contains(' ') && authors == lower))
        return {};
    authors.replace(QRegularExpression("\\s*;\\s*|\\s+and\\s+"), ", ");
    return authors;
}

// The title is usually the tallest text near the top of page one. Only trust it when it clearly
// stands out from body text; a wrong title is worse than the file name.
QString titleFromFirstPage(QPdfDocument &pdf)
{
    if (pdf.pageCount() < 1) return {};
    const auto size = pdf.pagePointSize(0);
    SelectionGeometry geometry;
    QList<QRectF> lines;
    for (const auto &value : geometry.lineRectangles(pdf.getAllText(0).bounds())) {
        const auto line = value.toRectF();
        // Skip rotated margin stamps (e.g. arXiv's) and specks.
        if (line.width() > line.height() * 2 && line.height() > 2) lines.append(line);
    }
    if (lines.size() < 3) return {};
    QList<qreal> heights;
    for (const auto &line : lines) heights.append(line.height());
    std::sort(heights.begin(), heights.end());
    const qreal body = heights[heights.size() / 2];
    qreal tallest = 0;
    for (const auto &line : lines)
        if (line.top() < size.height() * .45) tallest = std::max(tallest, line.height());
    if (tallest < body * 1.3) return {};
    QStringList parts;
    qreal lastBottom = -1;
    for (const auto &line : lines) {
        if (line.top() >= size.height() * .45) break;
        const bool titleLine = line.height() >= tallest * .85;
        if (!titleLine) {
            if (!parts.isEmpty()) break;
            continue;
        }
        if (!parts.isEmpty() && line.top() - lastBottom > tallest * 1.2) break;
        const qreal middle = line.center().y();
        const auto text = pdf.getSelection(0, QPointF(line.left() + .5, middle), QPointF(line.right() - .5, middle))
                              .text()
                              .simplified();
        if (!text.isEmpty()) parts.append(text);
        lastBottom = line.bottom();
        if (parts.size() == 4) break;
    }
    auto title = parts.join(' ');
    // Footnote markers attached to the title.
    title.remove(QRegularExpression("[\\*∗†‡]+$"));
    return title.trimmed();
}
}

PaperMetadata extractPaperMetadata(const QString &path)
{
    PaperMetadata result;
    QPdfDocument pdf;
    if (pdf.load(path) != QPdfDocument::Error::None || pdf.pageCount() < 1) return result;
    const auto fileName = QFileInfo(path).fileName();
    const auto field = [&](QPdfDocument::MetaDataField key) { return pdf.metaData(key).toString().simplified(); };
    const auto firstPage = pdf.getAllText(0).text();

    const auto declared = field(QPdfDocument::MetaDataField::Title);
    if (PaperMetadataText::usableTitle(declared, fileName))
        result.title = declared;
    else {
        const auto found = titleFromFirstPage(pdf);
        if (PaperMetadataText::usableTitle(found, fileName)) result.title = found;
    }
    result.authors = cleanAuthors(field(QPdfDocument::MetaDataField::Author));
    const auto declaredText
        = field(QPdfDocument::MetaDataField::Subject) + ' ' + field(QPdfDocument::MetaDataField::Keywords);
    result.doi = PaperMetadataText::findDoi(declaredText);
    if (result.doi.isEmpty()) result.doi = PaperMetadataText::findDoi(firstPage);
    result.arxiv = PaperMetadataText::findArxiv(firstPage);
    if (result.arxiv.isEmpty()) result.arxiv = arxivFromFileName(fileName);
    result.year = yearFromArxiv(result.arxiv);
    if (result.year.isEmpty()) {
        const auto created = pdf.metaData(QPdfDocument::MetaDataField::CreationDate).toDateTime();
        const int year = created.isValid() ? created.date().year() : 0;
        if (year >= 1900 && year <= QDate::currentDate().year() + 1) result.year = QString::number(year);
    }
    return result;
}
