#include "ReferenceFinder.h"
#include "PdfAccess.h"
#include "SelectionGeometry.h"

#include <QFileInfo>
#include <QPdfDocument>
#include <QPdfSelection>
#include <QRegularExpression>
#include <QThread>

#include <algorithm>

namespace {
// TABLE IV and Table 4 are the same table.
int tableNumber(const QString &text)
{
    bool ok = false;
    const int arabic = text.toInt(&ok);
    if (ok) return arabic;
    const QHash<QChar, int> values{{'I', 1}, {'V', 5}, {'X', 10}, {'L', 50}, {'C', 100}};
    int total = 0;
    for (qsizetype i = 0; i < text.size(); ++i) {
        const int value = values.value(text[i].toUpper(), -1);
        if (value < 0) return -1;
        const int next = i + 1 < text.size() ? values.value(text[i + 1].toUpper(), 0) : 0;
        total += value < next ? -value : value;
    }
    return total;
}

// Up to the end of the line (and `lines` more), at most `limit` characters.
qsizetype lineLength(const QString &text, qsizetype start, int lines = 0, qsizetype limit = 240)
{
    qsizetype end = start;
    for (int line = 0; line <= lines; ++line) {
        end = text.indexOf(QRegularExpression("[\\r\\n]"), end + 1);
        if (end < 0) {
            end = text.size();
            break;
        }
        if (line < lines)
            while (end + 1 < text.size() && (text[end + 1] == '\r' || text[end + 1] == '\n')) ++end;
    }
    return std::clamp<qsizetype>(end - start, 1, limit);
}

bool lineStart(const QString &text, qsizetype index)
{
    while (index > 0 && (text[index - 1] == ' ' || text[index - 1] == '\t')) --index;
    return index == 0 || text[index - 1] == '\n' || text[index - 1] == '\r';
}
// The text lines of a page (PDF points, top to bottom) and whether it is set in two columns (many
// lines in each half).
struct PageLines {
    QList<QRectF> lines;
    qreal width = 0;
    bool twoColumns = false;
};

PageLines pageLines(QPdfDocument &pdf, int page)
{
    PageLines result;
    result.width = pdf.pagePointSize(page).width();
    SelectionGeometry geometry;
    for (const auto &value : geometry.lineRectangles(pdf.getAllText(page).bounds())) result.lines << value.toRectF();
    // Sideways text (arXiv's stamp in the margin) is no line of the page.
    result.lines.removeIf([](const QRectF &r) { return r.height() > r.width() || r.height() > 60; });
    std::sort(
        result.lines.begin(), result.lines.end(), [](const QRectF &a, const QRectF &b) { return a.top() < b.top(); });
    int left = 0, right = 0;
    for (const auto &line : result.lines) {
        if (line.right() <= result.width * .55)
            ++left;
        else if (line.left() >= result.width * .45)
            ++right;
    }
    result.twoColumns = left >= 6 && right >= 6;
    return result;
}

// The column a box sits in: on a two-column page its half, unless it spans both; else the whole width.
QPair<qreal, qreal> columnOf(const PageLines &page, const QRectF &box)
{
    const qreal w = page.width;
    if (page.twoColumns) {
        if (box.right() <= w * .56) return {0, w * .5};
        if (box.left() >= w * .44) return {w * .5, w};
    }
    return {0, w};
}

QString lineText(QPdfDocument &pdf, int page, const QRectF &line)
{
    const qreal y = line.center().y();
    return pdf.getSelection(page, QPointF(line.left() + .5, y), QPointF(line.right() - .5, y)).text().simplified();
}

// Running text: several ordinary words (an equation has few, if any, besides function names), or a
// lead-in ending with a colon.
bool proseLine(const QString &text)
{
    static const QRegularExpression word("[A-Za-z]{3,}");
    static const QStringList math{"exp", "log", "sin", "cos", "tan", "max", "min", "arg", "argmax", "argmin", "sup",
        "inf", "lim", "det", "diag", "softmax", "sign", "tanh", "sigmoid", "relu", "mod", "var", "cov", "atan"};
    int words = 0;
    for (auto it = word.globalMatch(text); it.hasNext();)
        if (!math.contains(it.next().captured().toLower())) ++words;
    return words >= 4 || (words >= 2 && text.trimmed().endsWith(':'));
}

QVariantMap equationAround(QPdfDocument &pdf, int page, const QPointF &point);

bool mathLine(const QString &text)
{
    static const QRegularExpression math(QStringLiteral("[=≜≈≡≤≥<>∈∉⊂⊆∑∏∫∮∂∇√∞±×·⋅∘⊕⊗⊙⊞⊟→←↦‖∥]|[\\x{0370}-\\x{03FF}]|["
                                                        "\\x{1D400}-\\x{1D7FF}]|\\(\\d{1,3}[a-z]?\\)\\s*$"));
    return math.match(text).hasMatch();
}
} // namespace

ReferenceFinder::ReferenceFinder(std::shared_ptr<std::atomic_bool> readerBusy, QObject *parent)
    : QObject(parent), m_readerBusy(std::move(readerBusy))
{
    m_pool.setMaxThreadCount(1);
    m_pool.setThreadPriority(QThread::LowPriority);
}

ReferenceFinder::~ReferenceFinder()
{
    m_latest = INT_MAX;
    m_pool.waitForDone();
}

int ReferenceFinder::resolve(const QUrl &source, int page, const QPointF &point)
{
    const int request = ++m_next;
    m_latest = request;
    const auto path = source.toLocalFile();
    m_pool.start([this, request, path, page, point] {
        // Only the newest spot matters; older ones the pointer has already left.
        const auto target = request < m_latest ? QVariantMap() : find(path, page, point, request);
        QMetaObject::invokeMethod(
            this, [this, request, target] { emit resolved(request, target); }, Qt::QueuedConnection);
    });
    return request;
}

int ReferenceFinder::entryAt(const QUrl &source, int page, const QPointF &point)
{
    const int request = ++m_next;
    m_latest = request;
    const auto path = source.toLocalFile();
    m_pool.start([this, request, path, page, point] {
        const auto target = request < m_latest ? QVariantMap() : findEntry(path, page, point, request);
        QMetaObject::invokeMethod(
            this, [this, request, target] { emit resolved(request, target); }, Qt::QueuedConnection);
    });
    return request;
}

// An entry starts a line with "[n]" or "n."; it runs to the next one (or 400 characters).
QVariantMap ReferenceFinder::entryAround(const QString &text, qsizetype index)
{
    static const QRegularExpression entryStart(R"((?:^|[\r\n])[ \t]*(\[(\d{1,3})\]|(\d{1,3})\.[ \t]))");
    qsizetype start = -1;
    QString number;
    for (auto it = entryStart.globalMatch(text); it.hasNext();) {
        const auto m = it.next();
        if (m.capturedStart(1) > index + 2) break;
        start = m.capturedStart(1);
        number = m.captured(2).isEmpty() ? m.captured(3) : m.captured(2);
    }
    // Too far back to be the entry the point is on.
    if (start < 0 || index - start > 400) return {};
    const auto next = entryStart.match(text, start + 2);
    const auto end = next.hasMatch() ? next.capturedStart(1) : text.size();
    return {{"start", start}, {"length", std::clamp<qsizetype>(end - start, 1, 400)}, {"label", "[" + number + "]"}};
}

QVariantMap ReferenceFinder::findEntry(const QString &path, int page, const QPointF &point, int request)
{
    QPdfDocument pdf;
    if (path.isEmpty() || PdfAccess::load(pdf, path) != QPdfDocument::Error::None) return {};
    if (page < 0 || page >= pdf.pageCount()) return {};
    // Destinations point at the line's start or the margin: probe along the line for its first character.
    const auto width = pdf.pagePointSize(page).width();
    const qreal y = point.y() + 4;
    auto hit = pdf.getSelection(page, QPointF(point.x() + 2, y), QPointF(point.x() + 5, y));
    for (qreal x = 2; hit.text().isEmpty() && x < width; x += 10)
        hit = pdf.getSelection(page, QPointF(x, y), QPointF(x + 3, y));
    if (hit.text().isEmpty()) return {};
    const auto texts = pageTexts(pdf, path, request);
    if (page >= texts.size()) return {};
    const auto entry = entryAround(texts[page], hit.startIndex());
    if (entry.isEmpty()) return {};
    auto found = describe(pdf, texts, {{"page", page}, {"start", entry["start"]}, {"length", entry["length"]}});
    if (found.isEmpty()) return {};
    found.insert("kind", "citation");
    found.insert("label", entry["label"]);
    return found;
}

QVariantMap ReferenceFinder::find(const QString &path, int page, const QPointF &point, int request)
{
    QPdfDocument pdf;
    if (path.isEmpty() || PdfAccess::load(pdf, path) != QPdfDocument::Error::None) return {};
    if (page < 0 || page >= pdf.pageCount()) return {};
    for (int waited = 0; m_readerBusy && m_readerBusy->load() && waited < 100; ++waited) QThread::msleep(20);
    // The character under the pointer.
    auto hit = pdf.getSelection(page, point - QPointF(2, 0), point + QPointF(2, 0));
    if (hit.text().isEmpty()) hit = pdf.getSelection(page, point - QPointF(5, 0), point + QPointF(5, 0));
    if (hit.text().isEmpty()) return {};
    const auto texts = pageTexts(pdf, path, request);
    if (page >= texts.size()) return {};
    const auto reference = referenceAt(texts[page], hit.startIndex() + hit.text().size() / 2);
    if (reference.isEmpty()) return {};
    auto found = describe(pdf, texts, locate(texts, reference, page, reference["start"].toLongLong()));
    if (found.isEmpty()) return {};
    // Figures and tables: the whole float with its caption, not just the caption's first line.
    if (reference["kind"] == "figure" || reference["kind"] == "table") {
        const auto region = floatRegion(pdf, found["page"].toInt(),
            QRectF(found["x"].toDouble(), found["y"].toDouble(), found["width"].toDouble(), found["height"].toDouble()),
            reference["kind"] == "table");
        if (!region.isEmpty()) found.insert("float", region);
    }
    // An equation: its whole display, for Explain.
    if (reference["kind"] == "equation") {
        const auto region = equationAround(pdf, found["page"].toInt(),
            QPointF(found["x"].toDouble() + found["width"].toDouble() / 2,
                found["y"].toDouble() + found["height"].toDouble() / 2));
        if (!region.isEmpty()) found.insert("float", region);
    }
    found.insert("kind", reference["kind"]);
    found.insert("label", reference["label"]);
    // Several papers cited together ([3, 5], [12–14]): each one's entry, in order.
    const auto numbers = reference["numbers"].toStringList();
    if (numbers.size() > 1) {
        QVariantList entries;
        for (const auto &number : numbers) {
            auto one = reference;
            one.insert("key", number);
            auto entry = describe(pdf, texts, locate(texts, one, page, reference["start"].toLongLong()));
            if (entry.isEmpty()) continue;
            entry.insert("label", "[" + number + "]");
            entry.insert("current", number == reference["key"].toString());
            entries << entry;
        }
        if (entries.size() > 1) found.insert("entries", entries);
    }
    return found;
}

// Where a located target is on its page, and its text (line breaks and hyphenation undone).
QVariantMap ReferenceFinder::describe(QPdfDocument &pdf, const QStringList &texts, const QVariantMap &target)
{
    if (target.isEmpty()) return {};
    const int page = target["page"].toInt();
    const auto box
        = pdf.getSelectionAtIndex(page, target["start"].toInt(), target["length"].toInt()).boundingRectangle();
    const auto size = pdf.pagePointSize(page);
    if (box.isEmpty() || size.height() <= 0) return {};
    auto text = texts[page].mid(target["start"].toInt(), target["length"].toInt());
    // Words broken at a line end: PDF text marks the break with a hyphen or a hidden character (U+0002,
    // a soft hyphen, U+FFFE) that fonts cannot show; join the word, then drop any other control character.
    text.replace(QRegularExpression("[-\\x{0002}\\x{00AD}\\x{FFFE}]\\s*[\\r\\n]+\\s*"), "")
        .remove(
            QRegularExpression("[\\x{0000}-\\x{0008}\\x{000B}\\x{000C}\\x{000E}-\\x{001F}\\x{00AD}\\x{FFFE}\\x{FFFF}]"))
        .replace(QRegularExpression("\\s+"), " ");
    return {{"text", text.trimmed()}, {"page", page}, {"x", box.x()}, {"y", box.y()}, {"width", box.width()},
        {"height", box.height()}, {"top", box.y() / size.height()}};
}

QStringList ReferenceFinder::pageTexts(QPdfDocument &pdf, const QString &path, int)
{
    const auto modified = QFileInfo(path).lastModified();
    {
        QMutexLocker lock(&m_mutex);
        const auto cached = m_texts.constFind(path);
        if (cached != m_texts.constEnd() && cached->modified == modified) return cached->pages;
    }
    QStringList pages;
    for (int page = 0; page < pdf.pageCount(); ++page) {
        // Reading comes first: the viewer draws with the same PDF library.
        for (int waited = 0; m_readerBusy && m_readerBusy->load() && waited < 100; ++waited) QThread::msleep(20);
        pages << pdf.getAllText(page).text();
    }
    QMutexLocker lock(&m_mutex);
    m_texts.insert(path, {modified, pages});
    m_order.removeAll(path);
    m_order << path;
    while (m_order.size() > 2) m_texts.remove(m_order.takeFirst());
    return pages;
}

QVariantMap ReferenceFinder::referenceAt(const QString &text, qsizetype index)
{
    if (index < 0 || index >= text.size()) return {};
    const qsizetype from = qMax<qsizetype>(0, index - 80);
    const auto window = text.mid(from, 160);
    const auto at = index - from;
    const auto covers
        = [at](const QRegularExpressionMatch &m) { return m.capturedStart() <= at && at < m.capturedEnd(); };
    const auto result = [from](const QString &kind, const QString &key, const QString &label, qsizetype start) {
        return QVariantMap{{"kind", kind}, {"key", key}, {"label", label}, {"start", from + start}};
    };
    // [12], [3, 5], [2–4], and IEEE's [3]–[5]: every number cited (ranges spelled out, at most 8);
    // the key is the number under the pointer, else the first.
    static const QRegularExpression bracketRange(R"(\[(\d{1,3})\]\s*[–—‒\-]\s*\[(\d{1,3})\])");
    static const QRegularExpression cite(R"(\[(\s*\d{1,3}(?:\s*[,;–—‒\-]\s*\d{1,3})*\s*)\])");
    static const QRegularExpression item(R"((\d{1,3})(?:\s*[–—‒\-]\s*(\d{1,3}))?)");
    const auto citation = [&](const QRegularExpressionMatch &m, const QString &numbersText, qsizetype numbersStart) {
        QString key;
        QStringList numbers;
        for (auto n = item.globalMatch(numbersText); n.hasNext();) {
            const auto x = n.next();
            const int first = x.captured(1).toInt(), last = x.captured(2).isEmpty() ? first : x.captured(2).toInt();
            for (int value = first; value <= last && value - first < 20 && numbers.size() < 8; ++value)
                numbers << QString::number(value);
            // The number under the pointer (a range's ends count as themselves).
            for (const int group : {1, 2}) {
                const auto start = numbersStart + x.capturedStart(group);
                if (x.capturedStart(group) >= 0 && start <= at && at < start + x.capturedLength(group))
                    key = x.captured(group);
            }
        }
        if (numbers.isEmpty()) return QVariantMap();
        if (key.isEmpty()) key = numbers.first();
        auto found = result("citation", key, "[" + key + "]", m.capturedStart());
        found.insert("numbers", numbers);
        return found;
    };
    for (auto it = bracketRange.globalMatch(window); it.hasNext();) {
        const auto m = it.next();
        if (!covers(m)) continue;
        auto found = citation(m, m.captured(1) + "-" + m.captured(2), -window.size());
        if (found.isEmpty()) return {};
        // The key is whichever bracket the pointer is on.
        const auto key = at < m.capturedStart(2) - 1 ? m.captured(1) : m.captured(2);
        found.insert("key", key);
        found.insert("label", "[" + key + "]");
        return found;
    }
    for (auto it = cite.globalMatch(window); it.hasNext();) {
        const auto m = it.next();
        if (covers(m)) return citation(m, m.captured(1), m.capturedStart(1));
    }
    // A caption is the target itself, not a reference to follow.
    const auto caption = [&window](const QRegularExpressionMatch &m) {
        return lineStart(window, m.capturedStart())
            && QRegularExpression(R"(^\s*[:.|])").match(window.mid(m.capturedEnd())).hasMatch();
    };
    static const QRegularExpression figure(R"(\b(?:Figs?\.|Figures?|FIGS?\.?|FIGURES?|Fig)\s*(\d+))");
    for (auto it = figure.globalMatch(window); it.hasNext();) {
        const auto m = it.next();
        if (covers(m) && !caption(m))
            return result("figure", m.captured(1), "Figure " + m.captured(1), m.capturedStart());
    }
    static const QRegularExpression table(R"(\b(?:Tables?|TABLES?|Tab\.)\s*([IVXLC]+|\d+)\b)");
    for (auto it = table.globalMatch(window); it.hasNext();) {
        const auto m = it.next();
        if (covers(m) && !caption(m))
            return result("table", m.captured(1), "Table " + m.captured(1), m.capturedStart());
    }
    static const QRegularExpression equation(R"(\b(?:Eqs?\.|Equations?|eq\.)\s*\(?(\d+)\)?)");
    for (auto it = equation.globalMatch(window); it.hasNext();) {
        const auto m = it.next();
        if (covers(m)) return result("equation", m.captured(1), "Eq. (" + m.captured(1) + ")", m.capturedStart());
    }
    // Vaswani et al. (2017), (Graves and Schmidhuber, 2005), (Hochreiter, 1997).
    static const QRegularExpression authorYear(
        R"(([A-Z][\w'’\-]+)(\s+et\s+al\.?|\s+(?:and|&)\s+[A-Z][\w'’\-]+)?,?\s*\(?((?:19|20)\d{2})[a-z]?)",
        QRegularExpression::UseUnicodePropertiesOption);
    for (auto it = authorYear.globalMatch(window); it.hasNext();) {
        const auto m = it.next();
        const bool cited = !m.captured(2).isEmpty() || (m.capturedStart() > 0 && window[m.capturedStart() - 1] == '(');
        if (covers(m) && cited)
            return result("author", m.captured(1) + "|" + m.captured(3),
                m.captured(1) + (m.captured(2).trimmed().startsWith("et") ? " et al. " : " ") + m.captured(3),
                m.capturedStart());
    }
    return {};
}

QVariantMap ReferenceFinder::locate(
    const QStringList &pages, const QVariantMap &reference, int fromPage, qsizetype fromIndex)
{
    const auto kind = reference["kind"].toString(), key = reference["key"].toString();
    const auto elsewhere
        = [fromPage, fromIndex](int page, qsizetype start) { return page != fromPage || qAbs(start - fromIndex) > 24; };
    const auto at = [](int page, qsizetype start, qsizetype length) {
        return QVariantMap{{"page", page}, {"start", start}, {"length", length}};
    };
    // The reference list: after the last "References" heading.
    static const QRegularExpression heading(
        R"((?:^|[\r\n])[ \t]*(?:[IVX\d]+\.?[ \t]*)?(?:References|REFERENCES|R EFERENCES|Bibliography|BIBLIOGRAPHY|Literature Cited)[ \t]*(?=[\r\n]|$))");
    int listPage = -1;
    qsizetype listStart = 0;
    for (int page = pages.size() - 1; page >= 0 && listPage < 0; --page) {
        for (auto it = heading.globalMatch(pages[page]); it.hasNext();) {
            listPage = page;
            listStart = it.next().capturedEnd();
        }
    }
    if (kind == "citation") {
        const auto escaped = QRegularExpression::escape(key);
        const QRegularExpression bracket(R"((?:^|[\r\n])[ \t]*(\[)" + escaped + R"(\]))");
        const QRegularExpression dotted(R"((?:^|[\r\n])[ \t]*()" + escaped + R"(\.)[ \t]+\S)");
        static const QRegularExpression nextEntry(R"([\r\n][ \t]*(?:\[\d{1,3}\]|\d{1,3}\.[ \t]))");
        // "[12] A. Author…", or "12. A. Author…" only inside a reference list.
        for (const auto *pattern : {&bracket, &dotted}) {
            if (pattern == &dotted && listPage < 0) break;
            for (int page = qMax(0, listPage); page < pages.size(); ++page) {
                const auto &text = pages[page];
                for (auto it = pattern->globalMatch(text, page == listPage ? listStart : 0); it.hasNext();) {
                    const auto m = it.next();
                    const auto start = m.capturedStart(1);
                    if (!elsewhere(page, start)) continue;
                    const auto next = nextEntry.match(text, start + 2);
                    const auto end = next.hasMatch() ? next.capturedStart() : text.size();
                    return at(page, start, std::clamp<qsizetype>(end - start, 1, 400));
                }
            }
        }
        return {};
    }
    if (kind == "author") {
        if (listPage < 0) return {};
        const auto parts = key.split('|');
        const QRegularExpression surname("\\b" + QRegularExpression::escape(parts.value(0)) + "\\b");
        for (int page = listPage; page < pages.size(); ++page) {
            const auto &text = pages[page];
            qsizetype line = page == listPage ? listStart : 0;
            while (line < text.size()) {
                while (line < text.size() && (text[line] == '\r' || text[line] == '\n')) ++line;
                // The name early on the entry's first line, the year within the entry.
                const auto entry = text.mid(line, 300);
                const auto firstLine = entry.left(entry.indexOf(QRegularExpression("[\\r\\n]")));
                const auto name = surname.match(firstLine);
                if (name.hasMatch() && name.capturedStart() < 80
                    && entry.left(lineLength(text, line, 2, 300)).contains(parts.value(1)))
                    return at(page, line, lineLength(text, line, 2, 300));
                const auto next = text.indexOf(QRegularExpression("[\\r\\n]"), line);
                if (next < 0) break;
                line = next + 1;
            }
        }
        return {};
    }
    if (kind == "figure" || kind == "table") {
        const auto escaped = QRegularExpression::escape(key);
        // Captions start a line: "Fig. 3." / "Figure 3:" / "TABLE II", or a magazine's "FIG 3 Text…".
        const QRegularExpression caption = kind == "figure"
            ? QRegularExpression(R"((?:^|[\r\n])[ \t]*((?:Fig\.|Figure|FIG\.|FIGURE|Fig)[ \t]*)" + escaped
                  + R"()(?!\d)[ \t]*[:.|]|(?:^|[\r\n])[ \t]*((?:FIG|FIGURE)[ \t]+)" + escaped + R"()[ \t]+(?=[A-Z(]))")
            : QRegularExpression(R"((?:^|[\r\n])[ \t]*((?:TABLE|Table)[ \t]+([IVXLC]+|\d+))(?![\dA-Za-z]))");
        const QRegularExpression anywhere(R"(((?:Fig\.|Figure|FIG\.|FIGURE)[ \t]*)" + escaped + R"()(?!\d)[ \t]*[:.])");
        const int wanted = tableNumber(key);
        for (const auto *pattern : {&caption, &anywhere}) {
            if (pattern == &anywhere && kind != "figure") break;
            for (int page = 0; page < pages.size(); ++page) {
                for (auto it = pattern->globalMatch(pages[page]); it.hasNext();) {
                    const auto m = it.next();
                    if (kind == "table" && tableNumber(m.captured(2)) != wanted) continue;
                    // A figure caption matched either form; its start is the first group that took part.
                    const auto start = m.capturedStart(1) >= 0 ? m.capturedStart(1) : m.capturedStart(2);
                    if (elsewhere(page, start))
                        return at(page, start, lineLength(pages[page], start, kind == "table" ? 1 : 0));
                }
            }
        }
        return {};
    }
    if (kind == "equation") {
        // The number at the end of the equation's line.
        const QRegularExpression numbered(R"((\()" + QRegularExpression::escape(key) + R"(\))(?=[ \t]*(?:[\r\n]|$)))");
        for (int page = 0; page < pages.size(); ++page) {
            for (auto it = numbered.globalMatch(pages[page]); it.hasNext();) {
                const auto m = it.next();
                if (elsewhere(page, m.capturedStart(1))) return at(page, m.capturedStart(1), m.capturedLength(1));
            }
        }
    }
    return {};
}

QVariantMap ReferenceFinder::floatRegion(QPdfDocument &pdf, int page, const QRectF &captionLine, bool table)
{
    if (page < 0 || page >= pdf.pageCount() || captionLine.isEmpty()) return {};
    const auto size = pdf.pagePointSize(page);
    const auto layout = pageLines(pdf, page);
    const auto &lines = layout.lines;
    if (lines.isEmpty()) return {};
    // The caption's column: on a two-column page its half, unless the caption spans both.
    const qreal w = size.width();
    const auto column = columnOf(layout, captionLine);
    const qreal left = column.first, right = column.second;
    const auto inColumn = [&](const QRectF &r) { return r.center().x() >= left && r.center().x() <= right; };
    // The column's text block: figures sit within it.
    qreal blockLeft = captionLine.left(), blockRight = captionLine.right();
    for (const auto &line : lines)
        if (inColumn(line)) {
            blockLeft = std::min(blockLeft, line.left());
            blockRight = std::max(blockRight, line.right());
        }
    const qreal lineHeight = std::max<qreal>(6, captionLine.height());
    const qreal blockWidth = blockRight - blockLeft;
    // The caption: its first line and the lines that follow closely below it.
    QRectF caption = captionLine;
    for (const auto &line : lines) {
        if (!inColumn(line) || line.bottom() < captionLine.top()) continue;
        // The rest of the first line.
        if (line.top() < captionLine.top() + lineHeight * .5) {
            caption |= line;
            continue;
        }
        // Body text right after it: further down, or set in a larger type than the caption.
        if (line.top() - caption.bottom() > lineHeight * .9 || line.height() > captionLine.height() * 1.3) break;
        caption |= line;
    }
    // Body text: a long line with another long one just above or below it (labels in a figure are short).
    const auto isLong = [&](const QRectF &r) { return inColumn(r) && r.width() >= blockWidth * .6; };
    const auto paragraphLine = [&](qsizetype i) {
        if (!isLong(lines[i])) return false;
        for (const auto j : {i - 1, i + 1})
            if (j >= 0 && j < lines.size() && isLong(lines[j])
                && std::abs(lines[j].top() - lines[i].top()) < std::max(lineHeight, lines[i].height()) * 2)
                return true;
        return false;
    };
    qreal top = caption.top(), bottom = caption.bottom();
    if (!table) {
        // The figure above its caption, up to the body text before it (or the page's top margin).
        top = std::min<qreal>(caption.top(), 24);
        for (qsizetype i = lines.size() - 1; i >= 0; --i)
            if (lines[i].bottom() <= caption.top() - 2 && paragraphLine(i)) {
                top = lines[i].bottom() + 4;
                break;
            }
    } else {
        // The table below its caption, down to the body text after it (or the page's bottom margin).
        bottom = std::max<qreal>(caption.bottom(), size.height() - 24);
        for (qsizetype i = 0; i < lines.size(); ++i)
            if (lines[i].top() >= caption.bottom() + lineHeight * 1.5 && paragraphLine(i)) {
                bottom = lines[i].top() - 4;
                break;
            }
    }
    // Across: the column's text block, a little wider for drawings at its edges.
    const qreal from = std::max<qreal>(0, blockLeft - 8), to = std::min<qreal>(w, blockRight + 8);
    // From inside the first line's first glyph to inside the last line's last one.
    const qreal inset = std::min<qreal>(3, caption.height() / 3);
    const auto text = pdf.getSelection(page, QPointF(caption.left() + 1, caption.top() + inset),
                             QPointF(caption.right() - 1, caption.bottom() - inset))
                          .text()
                          .simplified();
    return {{"x", from}, {"y", top}, {"width", to - from}, {"height", bottom - top}, {"captionTop", caption.top()},
        {"captionBottom", caption.bottom()}, {"caption", text}};
}

int ReferenceFinder::objectAt(const QUrl &source, int page, const QPointF &point)
{
    const int request = ++m_next;
    const auto path = source.toLocalFile();
    m_pool.start([this, request, path, page, point] {
        QVariantMap target;
        QPdfDocument pdf;
        if (!path.isEmpty() && PdfAccess::load(pdf, path) == QPdfDocument::Error::None)
            target = findObject(pdf, page, point);
        QMetaObject::invokeMethod(
            this, [this, request, target] { emit objectFound(request, target); }, Qt::QueuedConnection);
    });
    return request;
}

namespace {
// An algorithm runs from its caption ("Algorithm 1 Name") down through numbered steps, Require/Ensure
// lines, control words and indented continuations, to the first ordinary line after it.
QRectF algorithmBox(QPdfDocument &pdf, int page, const QRectF &captionLine)
{
    const auto layout = pageLines(pdf, page);
    const auto column = columnOf(layout, captionLine);
    static const QRegularExpression step(
        R"(^\s*(\d{1,3}:|(?:Require|Ensure|Input|Output|Data|Result|Parameters?|Initiali[sz]e)\b|(?:end|while|for|if|else|return|repeat|until|function|procedure|do|then)\b))",
        QRegularExpression::CaseInsensitiveOption);
    const qreal lineHeight = std::max<qreal>(6, captionLine.height());
    qreal blockLeft = captionLine.left();
    for (const auto &line : layout.lines)
        if (line.center().x() >= column.first && line.center().x() <= column.second)
            blockLeft = std::min(blockLeft, line.left());
    QRectF box = captionLine;
    int taken = 0;
    for (const auto &line : layout.lines) {
        if (line.center().x() < column.first || line.center().x() > column.second) continue;
        if (line.top() < captionLine.bottom() - 1) continue;
        if (line.top() - box.bottom() > lineHeight * 2.2 || ++taken > 80) break;
        const auto text = lineText(pdf, page, line);
        if (!step.match(text).hasMatch() && line.left() < blockLeft + lineHeight && proseLine(text)) break;
        box |= line;
    }
    return box;
}

// A displayed equation around a point. Lines are taken in the PDF's reading order, where each column
// stays on its own: the line under the point and its neighbours, as long as they are not running text
// (an equation's pieces are short or mathematical), with the number "(N)" printed beside them.
QVariantMap equationAround(QPdfDocument &pdf, int page, const QPointF &point)
{
    const auto all = pdf.getAllText(page).text();
    qsizetype index = -1;
    for (const qreal reach : {2.0, 6.0, 14.0}) {
        const auto hit = pdf.getSelection(page, point - QPointF(reach, 0), point + QPointF(reach, 0));
        if (!hit.text().trimmed().isEmpty()) {
            index = hit.startIndex();
            break;
        }
    }
    if (index < 0 || index >= all.size()) return {};
    QList<QPair<qsizetype, qsizetype>> lines; // Start and end of each line.
    for (qsizetype from = 0; from < all.size();) {
        auto to = from;
        while (to < all.size() && all[to] != '\r' && all[to] != '\n') ++to;
        if (to > from) lines.append({from, to});
        from = to + 1;
    }
    qsizetype at = -1;
    for (qsizetype i = 0; i < lines.size() && at < 0; ++i)
        if (index >= lines[i].first && index < lines[i].second) at = i;
    if (at < 0) return {};
    const auto text
        = [&](qsizetype i) { return all.mid(lines[i].first, lines[i].second - lines[i].first).simplified(); };
    const auto boxOf = [&](qsizetype i) {
        return pdf.getSelectionAtIndex(page, lines[i].first, lines[i].second - lines[i].first).boundingRectangle();
    };
    // On a two-column page the equation stays in the point's column; reading order sometimes jumps across.
    const auto layout = pageLines(pdf, page);
    const qreal middle = layout.width / 2;
    const auto otherColumn = [&](qsizetype i) {
        if (!layout.twoColumns) return false;
        const auto box = boxOf(i);
        return !box.isEmpty() && (point.x() < middle ? box.left() >= middle - 5 : box.right() <= middle + 5);
    };
    const auto part = [&](qsizetype i) {
        const auto line = text(i);
        static const QRegularExpression words("[A-Za-z]{3,}.*[A-Za-z]{3,}.*[A-Za-z]{3,}");
        return !proseLine(line) && (mathLine(line) || (line.size() < 30 && !words.match(line).hasMatch()))
            && !otherColumn(i);
    };
    if (!part(at)) return {};
    QList<qsizetype> taken{at};
    for (auto i = at - 1; i >= 0 && at - i <= 80 && part(i); --i) taken.prepend(i);
    for (auto i = at + 1; i < lines.size() && i - at <= 80 && part(i); ++i) taken.append(i);
    QStringList caption;
    QRectF box;
    bool math = false;
    for (const auto i : std::as_const(taken)) {
        caption << text(i);
        math = math || mathLine(caption.last());
        box |= boxOf(i);
    }
    if (!math || box.isEmpty()) return {};
    // The equation's number: "(N)" at the height of the block, right of its middle ("SE(3)" is no
    // number); of several, the one nearest the point.
    static const QRegularExpression tag(R"((?:^|\s)\((\d{1,3}[a-z]?)\))");
    QString number;
    qreal nearest = 1e9;
    for (auto it = tag.globalMatch(all); it.hasNext();) {
        const auto m = it.next();
        const auto found
            = pdf.getSelectionAtIndex(page, m.capturedStart(1) - 1, m.capturedLength(1) + 2).boundingRectangle();
        if (found.isEmpty() || found.bottom() < box.top() - 4 || found.top() > box.bottom() + 4) continue;
        if (found.left() < box.center().x() || found.left() > box.right() + 60) continue;
        if (layout.twoColumns && (point.x() < middle) != (found.center().x() < middle)) continue;
        const qreal distance = std::abs(found.center().y() - point.y());
        if (distance < nearest) {
            nearest = distance;
            number = m.captured(1);
        }
        box |= found;
    }
    box.adjust(-6, -4, 6, 4);
    return {{"kind", "equation"},
        {"label", number.isEmpty() ? QStringLiteral("Equation") : "Equation (" + number + ")"}, {"page", page},
        {"x", std::max<qreal>(0, box.x())}, {"y", std::max<qreal>(0, box.y())}, {"width", box.width()},
        {"height", box.height()}, {"caption", caption.join(' ').left(600)}};
}
} // namespace

QVariantMap ReferenceFinder::findObject(QPdfDocument &pdf, int page, const QPointF &point)
{
    if (page < 0 || page >= pdf.pageCount()) return {};
    const auto text = pdf.getAllText(page).text();
    // Figures, tables and algorithms by their captions: the one whose area holds the point.
    static const QRegularExpression caption(
        R"((?:^|[\r\n])[ \t]*(?:((?:Fig\.|Figure|FIG\.|FIGURE|Fig)[ \t]*(\d+)[ \t]*[:.|])|((?:TABLE|Table)[ \t]+([IVXLC]+|\d+))(?![\dA-Za-z])|(Algorithm[ \t]+(\d+))(?!\d)))");
    static const QRegularExpression steps(R"((?:Require|Ensure|Input|Output|Data|Result)\s*:|[\r\n][ \t]*1:)");
    for (auto it = caption.globalMatch(text); it.hasNext();) {
        const auto m = it.next();
        const int group = m.capturedStart(1) >= 0 ? 1 : m.capturedStart(3) >= 0 ? 3 : 5;
        const auto start = m.capturedStart(group);
        const auto line = pdf.getSelectionAtIndex(page, start, lineLength(text, start)).boundingRectangle();
        if (line.isEmpty()) continue;
        QVariantMap found;
        if (group == 5) {
            // "Algorithm 1 summarizes …" in running text is a mention, not a caption: steps follow a caption.
            if (!steps.match(text.mid(m.capturedEnd(), 400)).hasMatch()) continue;
            const auto box = algorithmBox(pdf, page, line);
            const auto head = pdf.getSelection(page, QPointF(line.left() + 1, line.center().y()),
                                     QPointF(line.right() - 1, line.center().y()))
                                  .text()
                                  .simplified();
            found = {{"kind", "algorithm"}, {"label", "Algorithm " + m.captured(6)}, {"x", box.left() - 4},
                {"y", box.top() - 3}, {"width", box.width() + 8}, {"height", box.height() + 6}, {"caption", head}};
        } else {
            const bool table = group == 3;
            found = floatRegion(pdf, page, line, table);
            if (found.isEmpty()) continue;
            found.insert("kind", table ? "table" : "figure");
            found.insert("label", table ? "Table " + m.captured(4) : "Figure " + m.captured(2));
        }
        const QRectF area(
            found["x"].toDouble(), found["y"].toDouble(), found["width"].toDouble(), found["height"].toDouble());
        if (!area.adjusted(-4, -4, 4, 4).contains(point)) continue;
        found.insert("page", page);
        return found;
    }
    return equationAround(pdf, page, point);
}

int ReferenceFinder::wordAt(const QUrl &source, int page, const QPointF &point)
{
    const int request = ++m_next;
    const auto path = source.toLocalFile();
    m_pool.start([this, request, path, page, point] {
        QVariantMap word;
        QPdfDocument pdf;
        if (!path.isEmpty() && PdfAccess::load(pdf, path) == QPdfDocument::Error::None && page >= 0
            && page < pdf.pageCount()) {
            const auto hit = pdf.getSelection(page, point - QPointF(1.5, 0), point + QPointF(1.5, 0));
            if (!hit.text().trimmed().isEmpty()) {
                const auto all = pdf.getAllText(page).text();
                // The word: the characters around the hit up to spaces and punctuation that is not math.
                const auto boundary
                    = [](QChar c) { return c.isSpace() || QStringLiteral(",;:()[]{}\"'“”").contains(c); };
                qsizetype from = hit.startIndex(), to = hit.startIndex() + 1;
                while (from > 0 && !boundary(all[from - 1]) && hit.startIndex() - from < 24) --from;
                while (to < all.size() && !boundary(all[to]) && to - hit.startIndex() < 24) ++to;
                auto text = all.mid(from, to - from);
                while (text.endsWith('.')) text.chop(1);
                const auto box = pdf.getSelectionAtIndex(page, from, to - from).boundingRectangle();
                word = {{"word", text}, {"glyph", hit.text().trimmed().left(2)}, {"x", box.x()}, {"y", box.y()},
                    {"width", box.width()}, {"height", box.height()}};
            }
        }
        QMetaObject::invokeMethod(this, [this, request, word] { emit wordFound(request, word); }, Qt::QueuedConnection);
    });
    return request;
}
