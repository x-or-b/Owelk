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

struct Line {
    QRectF box;
    QString text;
};

// Lines of the upper part of page one with their text. Rotated margin stamps (e.g. arXiv's) and specks are skipped.
QList<Line> upperLines(QPdfDocument &pdf, qreal limit)
{
    const auto size = pdf.pagePointSize(0);
    SelectionGeometry geometry;
    QList<Line> lines;
    for (const auto &value : geometry.lineRectangles(pdf.getAllText(0).bounds())) {
        const auto box = value.toRectF();
        if (box.width() <= box.height() * 2 || box.height() <= 2) continue;
        Line line{box, {}};
        if (box.top() < size.height() * limit) {
            const qreal middle = box.center().y();
            line.text = pdf.getSelection(0, QPointF(box.left() + .5, middle), QPointF(box.right() - .5, middle))
                            .text()
                            .simplified();
        }
        lines.append(line);
    }
    return lines;
}

bool bannerLine(const QString &text)
{
    // Venue, publisher and preprint banners printed above or beside the title.
    static const QRegularExpression banner("^(proceedings|journal|conference|published|accepted|under review|preprint|"
                                           "arxiv|vol\\.|volume|ieee|acm|springer|elsevier|copyright|©|workshop|"
                                           "technical report)",
        QRegularExpression::CaseInsensitiveOption);
    return text.contains(banner);
}

bool sectionStart(const QString &text)
{
    static const QRegularExpression start("^(abstract|a b s t r a c t|introduction|1\\.?\\s+introduction|keywords|"
                                          "index terms)\\b",
        QRegularExpression::CaseInsensitiveOption);
    return text.contains(start);
}

// The title is the tallest text near the top of page one, trusted only when it clearly stands out from body
// text: a wrong title is worse than the file name. The lines after it, up to the abstract, hold the authors.
PaperMetadata readFirstPage(QPdfDocument &pdf)
{
    PaperMetadata result;
    if (pdf.pageCount() < 1) return result;
    const auto size = pdf.pagePointSize(0);
    const auto lines = upperLines(pdf, .55);
    if (lines.size() < 3) return result;
    QList<qreal> heights;
    for (const auto &line : lines) heights.append(line.box.height());
    std::sort(heights.begin(), heights.end());
    const qreal body = heights[heights.size() / 2];
    const auto candidate = [&](const Line &line) {
        return line.box.top() < size.height() * .45 && line.box.top() > size.height() * .04 && !line.text.isEmpty()
            && !bannerLine(line.text);
    };
    qreal tallest = 0;
    for (const auto &line : lines)
        if (candidate(line)) tallest = std::max(tallest, line.box.height());
    if (tallest < body * 1.3) return result;
    QStringList parts;
    qsizetype after = -1;
    for (qsizetype i = 0; i < lines.size(); ++i) {
        const auto &line = lines[i];
        // Title lines share one size; allow 15% for mixed glyph heights.
        const bool titleLine = candidate(line) && line.box.height() >= tallest * .85;
        if (!titleLine) {
            if (!parts.isEmpty()) break;
            continue;
        }
        if (!parts.isEmpty() && line.box.top() - lines[after].box.bottom() > tallest * 1.2) break;
        parts.append(line.text);
        after = i;
        if (parts.size() == 4) break;
    }
    result.title = parts.join(' ');
    result.title.remove(QRegularExpression("[\\*∗†‡]+$")); // Footnote markers attached to the title.
    result.title = result.title.trimmed();
    QStringList authorLines;
    for (qsizetype i = after + 1; i >= 1 && i < lines.size() && authorLines.size() < 6; ++i) {
        const auto &line = lines[i];
        if (line.text.isEmpty() || sectionStart(line.text) || line.box.top() > size.height() * .55) break;
        authorLines.append(line.text);
    }
    result.authors = PaperMetadataText::authorNames(authorLines).join(", ");
    return result;
}
}

namespace PaperMetadataText {
QStringList authorNames(const QStringList &lines)
{
    static const QRegularExpression affiliation(
        "(universit|institut|laborator|\\blab\\b|department|school|college|academy|centre|center|inc\\.|ltd|corp|"
        "research|google|microsoft|meta\\b|deepmind|openai|nvidia|@|https?:|www\\.|\\.edu|\\.com|\\.org|street|road|"
        "\\bcity\\b|china|korea|usa|germany|japan|france|canada|kingdom)",
        QRegularExpression::CaseInsensitiveOption);
    static const QRegularExpression separators("\\s*(,|;|·|•|\\band\\b|&)\\s*");
    static const QRegularExpression markers("[0-9*∗†‡§¶♯⋆,]+|\\s[a-e]$");
    static const QRegularExpression word(
        "^(\\p{Lu}[\\p{L}'’\\-]*\\.?|\\p{Lu}\\.|van|von|de|der|den|da|di|du|le|la|del)$");
    QStringList names;
    for (const auto &line : lines) {
        if (line.contains(affiliation)) continue;
        for (auto part : line.split(separators, Qt::SkipEmptyParts)) {
            part.remove(markers);
            part = part.simplified();
            const auto words = part.split(' ', Qt::SkipEmptyParts);
            if (words.size() < 2 || words.size() > 4) continue;
            if (!std::all_of(words.cbegin(), words.cend(), [](const QString &w) { return word.match(w).hasMatch(); }))
                continue;
            if (!names.contains(part)) names.append(part);
            if (names.size() == 30) return names;
        }
    }
    return names;
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

    const auto page = readFirstPage(pdf);
    const auto declared = field(QPdfDocument::MetaDataField::Title);
    if (PaperMetadataText::usableTitle(declared, fileName))
        result.title = declared;
    else if (PaperMetadataText::usableTitle(page.title, fileName))
        result.title = page.title;
    // Declared authors are often an account name; the first page is the fallback.
    result.authors = cleanAuthors(field(QPdfDocument::MetaDataField::Author));
    if (result.authors.isEmpty()) result.authors = page.authors;
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
