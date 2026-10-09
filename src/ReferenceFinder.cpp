#include "ReferenceFinder.h"
#include "PdfAccess.h"
#include "SelectionGeometry.h"

#include <QFileInfo>
#include <QPdfDocument>
#include <QPdfSelection>
#include <QRegularExpression>
#include <QThread>

#include <algorithm>
#include <numeric>

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
// The text lines of a page (PDF points, top to bottom) and, on a two-column page, the gutter between
// the columns. Lines never run across the gutter: a tall line (sub- and superscripts) beside a line of
// the other column would otherwise join it and hide both from their columns.
struct PageLines {
    QString text; // The page's text, from the same (costly) reading as the lines.
    QList<QRectF> lines;
    qreal width = 0;
    qreal gutter = 0;
    bool twoColumns = false;
};

PageLines pageLines(QPdfDocument &pdf, int page)
{
    PageLines result;
    const qreal w = result.width = pdf.pagePointSize(page).width();
    result.gutter = w / 2;
    const auto all = pdf.getAllText(page);
    result.text = all.text();
    // Runs of text; sideways text (arXiv's stamp in the margin) is no part of a line.
    const auto polygons = all.bounds();
    QList<qreal> heights;
    for (const auto &polygon : polygons) heights << polygon.boundingRect().height();
    std::nth_element(heights.begin(), heights.begin() + heights.size() / 2, heights.end());
    const qreal typical = heights.isEmpty() ? 10 : heights[heights.size() / 2];
    QList<QPolygonF> runs;
    QList<QRectF> boxes;
    for (const auto &polygon : polygons) {
        const auto r = polygon.boundingRect();
        if (r.isEmpty() || (r.height() > r.width() && r.height() > std::max<qreal>(30, typical * 3))) continue;
        runs << polygon;
        boxes << r;
    }
    // Runs are as small as one character: join them into segments, words and the spaces between them,
    // but not across a wide gap such as a gutter.
    QList<qsizetype> order(runs.size());
    std::iota(order.begin(), order.end(), 0);
    std::sort(order.begin(), order.end(), [&](qsizetype a, qsizetype b) { return boxes[a].top() < boxes[b].top(); });
    QList<QList<qsizetype>> rows;
    QList<QRectF> rowBoxes;
    for (const auto i : std::as_const(order)) {
        const auto &r = boxes[i];
        qsizetype row = -1;
        for (qsizetype j = rows.size() - 1; j >= 0 && j >= rows.size() - 8 && row < 0; --j) {
            const auto &other = rowBoxes[j];
            if (std::min(other.bottom(), r.bottom()) - std::max(other.top(), r.top())
                >= std::min(other.height(), r.height()) * .5)
                row = j;
        }
        if (row < 0) {
            rows.append(QList<qsizetype>());
            rowBoxes.append(r);
            row = rows.size() - 1;
        }
        rows[row].append(i);
        rowBoxes[row] |= r;
    }
    QList<QRectF> segments;
    QList<qsizetype> segmentOf(runs.size());
    for (auto &row : rows) {
        std::sort(row.begin(), row.end(), [&](qsizetype a, qsizetype b) { return boxes[a].left() < boxes[b].left(); });
        for (const auto i : std::as_const(row)) {
            if (i == row.first() || boxes[i].left() - segments.last().right() > typical * .8)
                segments.append(boxes[i]);
            else
                segments.last() |= boxes[i];
            segmentOf[i] = segments.size() - 1;
        }
    }
    // The gutter: the middle band of the page that the fewest segments cross.
    const int band = int(w * .2);
    QList<int> crossing(band + 1, 0);
    for (const auto &r : std::as_const(segments)) {
        const int from = std::max(0, int(std::floor(r.left() - w * .4)) + 1);
        const int to = std::min(band, int(std::ceil(r.right() - w * .4)) - 1);
        for (int x = from; x <= to; ++x) ++crossing[x];
    }
    int fewest = INT_MAX;
    qreal from = 0, to = 0;
    for (int x = 0; x <= band; ++x) {
        if (crossing[x] < fewest) {
            fewest = crossing[x];
            from = to = x;
        } else if (crossing[x] == fewest && x == to + 1) {
            to = x;
        }
    }
    QList<QPolygonF> left, right, across;
    const qreal gutter = w * .4 + (from + to) / 2;
    int leftSegments = 0, rightSegments = 0;
    for (const auto &r : std::as_const(segments)) {
        if (r.right() <= gutter + 2)
            ++leftSegments;
        else if (r.left() >= gutter - 2)
            ++rightSegments;
    }
    for (qsizetype i = 0; i < runs.size(); ++i) {
        const auto &r = segments[segmentOf[i]];
        (r.right() <= gutter + 2 ? left : r.left() >= gutter - 2 ? right : across) << runs[i];
    }
    result.twoColumns
        = leftSegments >= 6 && rightSegments >= 6 && fewest <= std::max<qsizetype>(2, segments.size() / 30);
    SelectionGeometry geometry;
    const auto add = [&](const QList<QPolygonF> &part) {
        for (const auto &value : geometry.lineRectangles(part)) result.lines << value.toRectF();
    };
    if (result.twoColumns) {
        result.gutter = gutter;
        add(left);
        add(right);
        add(across);
    } else {
        add(runs);
    }
    std::sort(
        result.lines.begin(), result.lines.end(), [](const QRectF &a, const QRectF &b) { return a.top() < b.top(); });
    return result;
}

// The column a box sits in: on a two-column page its side of the gutter, unless it spans both; else the
// whole width.
QPair<qreal, qreal> columnOf(const PageLines &page, const QRectF &box)
{
    if (page.twoColumns) {
        if (box.right() <= page.gutter + 6) return {0, page.gutter};
        if (box.left() >= page.gutter - 6) return {page.gutter, page.width};
    }
    return {0, page.width};
}

// The character under a point (PDF points), or -1 when none is within `tolerance`. A selection from the
// point to the right starts at the character under it; when nothing lies to the right (a line's end),
// one to the left ends there. (A selection that starts and ends on one character is empty, so a short
// one around the point finds nothing in the middle of a glyph.)
int charAt(QPdfDocument &pdf, int page, const QPointF &point, qreal tolerance)
{
    QList<int> candidates;
    const auto rightward = pdf.getSelection(page, point, point + QPointF(30, 0));
    if (!rightward.text().isEmpty()) candidates << rightward.startIndex();
    if (candidates.isEmpty()) {
        const auto leftward = pdf.getSelection(page, point - QPointF(30, 0), point);
        if (!leftward.text().isEmpty()) {
            const int end = leftward.startIndex() + int(leftward.text().size());
            candidates << end - 1 << end << end - 2;
        }
    }
    for (const int index : std::as_const(candidates)) {
        if (index < 0) continue;
        const auto box = pdf.getSelectionAtIndex(page, index, 1).boundingRectangle();
        if (box.adjusted(-tolerance, -tolerance, tolerance, tolerance).contains(point)) return index;
    }
    return -1;
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
    const int index = charAt(pdf, page, point, 3);
    if (index < 0) return {};
    const auto texts = pageTexts(pdf, path, request);
    if (page >= texts.size()) return {};
    const auto reference = referenceAt(texts[page], index);
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

namespace {
// A caption on a page: "Fig. 3:", "TABLE II", or "Algorithm 1" followed by its steps.
struct Caption {
    QString kind, label;
    QRectF line; // Its first line (PDF points).
};

QList<Caption> captionsOn(QPdfDocument &pdf, int page, const QString &text)
{
    static const QRegularExpression caption(
        R"((?:^|[\r\n])[ \t]*(?:((?:Fig\.|Figure|FIG\.|FIGURE|Fig)[ \t]*(\d+)[ \t]*[:.|])|((?:TABLE|Table)[ \t]+([IVXLC]+|\d+))(?![\dA-Za-z])|(Algorithm[ \t]+(\d+))(?!\d)))");
    // "Algorithm 1 summarizes …" in running text is a mention, not a caption: steps follow a caption.
    static const QRegularExpression steps(R"((?:Require|Ensure|Input|Output|Data|Result)\s*:|[\r\n][ \t]*1:)");
    QList<Caption> found;
    for (auto it = caption.globalMatch(text); it.hasNext();) {
        const auto m = it.next();
        const int group = m.capturedStart(1) >= 0 ? 1 : m.capturedStart(3) >= 0 ? 3 : 5;
        if (group == 5 && !steps.match(text.mid(m.capturedEnd(), 400)).hasMatch()) continue;
        const auto start = m.capturedStart(group);
        const auto line = pdf.getSelectionAtIndex(page, int(start), int(lineLength(text, start))).boundingRectangle();
        if (line.isEmpty()) continue;
        found.append({group == 1 ? "figure"
                : group == 3     ? "table"
                                 : "algorithm",
            group == 1       ? "Figure " + m.captured(2)
                : group == 3 ? "Table " + m.captured(4)
                             : "Algorithm " + m.captured(6),
            line});
    }
    return found;
}

// A figure or table around its caption. The column is the caption's; the area runs to the body text
// before a figure (after a table), and never past another caption in the same column.
QVariantMap floatIn(QPdfDocument &pdf, int page, const PageLines &layout, const QList<Caption> &captions,
    const QRectF &captionLine, bool table)
{
    const auto &lines = layout.lines;
    if (lines.isEmpty()) return {};
    const qreal w = layout.width, height = pdf.pagePointSize(page).height();
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
    // A caption: its first line and the lines that follow closely below it, in the same type.
    const auto captionBlock = [&](const QRectF &first) {
        QRectF block = first;
        for (const auto &line : lines) {
            if (!inColumn(line) || line.bottom() < first.top()) continue;
            if (line.top() < first.top() + lineHeight * .5) {
                block |= line;
                continue;
            }
            if (line.top() - block.bottom() > lineHeight * .9 || line.height() > first.height() * 1.3) break;
            block |= line;
        }
        return block;
    };
    const auto caption = captionBlock(captionLine);
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
        bottom = std::max<qreal>(caption.bottom(), height - 24);
        for (qsizetype i = 0; i < lines.size(); ++i)
            if (lines[i].top() >= caption.bottom() + lineHeight * 1.5 && paragraphLine(i)) {
                bottom = lines[i].top() - 4;
                break;
            }
    }
    // Another float's caption in the same column ends this one.
    for (const auto &other : captions) {
        if (other.line.intersects(captionLine) || !inColumn(other.line)) continue;
        if (!table && other.line.bottom() <= caption.top() - 2)
            top = std::max(top, captionBlock(other.line).bottom() + 4);
        if (table && other.line.top() >= caption.bottom() + 2) bottom = std::min(bottom, other.line.top() - 4);
    }
    // Across: the column's text block, a little wider for drawings at its edges.
    const qreal from = std::max<qreal>(0, blockLeft - 8), to = std::min<qreal>(w, blockRight + 8);
    return {{"x", from}, {"y", top}, {"width", to - from}, {"height", bottom - top}, {"captionTop", caption.top()},
        {"captionLeft", caption.left()}, {"captionRight", caption.right()}, {"captionBottom", caption.bottom()}};
}

// The caption's words, read from inside its first line's first glyph to inside its last line's last one.
QString captionText(QPdfDocument &pdf, int page, const QVariantMap &region)
{
    const QRectF caption(QPointF(region["captionLeft"].toDouble(), region["captionTop"].toDouble()),
        QPointF(region["captionRight"].toDouble(), region["captionBottom"].toDouble()));
    const qreal inset = std::min<qreal>(3, caption.height() / 3);
    return pdf
        .getSelection(page, QPointF(caption.left() + 1, caption.top() + inset),
            QPointF(caption.right() - 1, caption.bottom() - inset))
        .text()
        .simplified();
}

// An algorithm runs from its caption ("Algorithm 1 Name") down through numbered steps, Require/Ensure
// lines, control words and indented continuations, to the first ordinary line after it.
QRectF algorithmBox(QPdfDocument &pdf, int page, const PageLines &layout, const QRectF &captionLine)
{
    const auto column = columnOf(layout, captionLine);
    static const QRegularExpression step(
        R"(^\s*(\d{1,3}(?::|\s*$)|(?:Require|Ensure|Input|Output|Data|Result|Parameters?|Initiali[sz]e)\b|(?:end|while|for|if|else|return|repeat|until|function|procedure|do|then)\b))",
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
        if (line.top() - box.bottom() > lineHeight * 2.2 || ++taken > 120) break;
        // Short or indented lines are steps; only a long line at the column's edge may be the text after.
        const bool plain = line.left() < blockLeft + lineHeight && line.width() > (column.second - column.first) * .6;
        if (plain) {
            const auto text = lineText(pdf, page, line);
            if (!step.match(text).hasMatch() && proseLine(text)) break;
        }
        box |= line;
    }
    return box;
}
} // namespace

QVariantMap ReferenceFinder::floatRegion(QPdfDocument &pdf, int page, const QRectF &captionLine, bool table)
{
    if (page < 0 || page >= pdf.pageCount() || captionLine.isEmpty()) return {};
    const auto layout = pageLines(pdf, page);
    auto region = floatIn(pdf, page, layout, captionsOn(pdf, page, layout.text), captionLine, table);
    if (!region.isEmpty()) region.insert("caption", captionText(pdf, page, region));
    return region;
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
// A displayed equation around a point. Lines are taken in the PDF's reading order, where each column
// stays on its own: the line under the point and its neighbours, as long as they are not running text
// (an equation's pieces are short or mathematical), with the number "(N)" printed beside them.
QVariantMap equationAround(QPdfDocument &pdf, int page, const QPointF &point, const PageLines &layout)
{
    // Equations are spaced out: a point between their symbols looks a little to each side.
    qsizetype index = -1;
    for (const qreal dx : {0.0, -10.0, 10.0, -20.0, 20.0})
        if ((index = charAt(pdf, page, point + QPointF(dx, 0), 6)) >= 0) break;
    const auto &all = layout.text;
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
    const auto part = [&](qsizetype i) {
        const auto line = text(i);
        static const QRegularExpression words("[A-Za-z]{3,}.*[A-Za-z]{3,}.*[A-Za-z]{3,}");
        return !proseLine(line) && (mathLine(line) || (line.size() < 30 && !words.match(line).hasMatch()));
    };
    if (!part(at)) return {};
    qsizetype first = at, last = at;
    while (first > 0 && at - first < 80 && part(first - 1)) --first;
    while (last + 1 < lines.size() && last - at < 80 && part(last + 1)) ++last;
    // The lines from a to b, as one selection (each reading of the PDF's text costs alike, whatever its length).
    const auto range = [&](qsizetype a, qsizetype b) {
        return pdf.getSelectionAtIndex(page, int(lines[a].first), int(lines[b].second - lines[a].first));
    };
    // On a two-column page the equation stays in the point's column; reading order sometimes jumps
    // across. The farthest lines on each side that keep it there are found by halving.
    const bool leftColumn = point.x() < layout.gutter;
    const auto inColumn = [&](qsizetype a, qsizetype b) {
        if (!layout.twoColumns) return true;
        for (const auto &polygon : range(a, b).bounds()) {
            const auto r = polygon.boundingRect();
            if (leftColumn ? r.left() >= layout.gutter - 5 : r.right() <= layout.gutter + 5) return false;
        }
        return true;
    };
    if (!inColumn(first, last)) {
        for (qsizetype low = first, high = at; low < high;) {
            const auto middle = (low + high) / 2;
            if (inColumn(middle, at))
                high = middle;
            else
                low = middle + 1;
            first = high;
        }
        for (qsizetype low = at, high = last; low < high;) {
            const auto middle = (low + high + 1) / 2;
            if (inColumn(at, middle))
                low = middle;
            else
                high = middle - 1;
            last = low;
        }
    }
    QStringList caption;
    bool math = false;
    for (auto i = first; i <= last; ++i) {
        caption << text(i);
        math = math || mathLine(caption.last());
    }
    auto box = range(first, last).boundingRectangle();
    if (!math || box.isEmpty()) return {};
    // The equation's number: "(N)" at the height of the block, right of its middle ("SE(3)" is no
    // number); of several, the one nearest the point. Numbers sit near the equation in reading order.
    static const QRegularExpression tag(R"((?:^|\s)\((\d{1,3}[a-z]?)\))");
    QString number;
    qreal nearest = 1e9;
    const auto from = std::max<qsizetype>(0, lines[first].first - 400);
    const auto window = all.mid(from, lines[last].second + 400 - from);
    for (auto it = tag.globalMatch(window); it.hasNext();) {
        const auto m = it.next();
        const auto found
            = pdf.getSelectionAtIndex(page, int(from + m.capturedStart(1) - 1), int(m.capturedLength(1) + 2))
                  .boundingRectangle();
        if (found.isEmpty() || found.bottom() < box.top() - 4 || found.top() > box.bottom() + 4) continue;
        if (found.left() < box.center().x() || found.left() > box.right() + 60) continue;
        if (layout.twoColumns && leftColumn != (found.center().x() < layout.gutter)) continue;
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

QVariantMap equationAround(QPdfDocument &pdf, int page, const QPointF &point)
{
    return equationAround(pdf, page, point, pageLines(pdf, page));
}
} // namespace

QVariantMap ReferenceFinder::findObject(QPdfDocument &pdf, int page, const QPointF &point)
{
    if (page < 0 || page >= pdf.pageCount()) return {};
    const auto layout = pageLines(pdf, page);
    const auto captions = captionsOn(pdf, page, layout.text);
    // Algorithms are measured from their own lines, so one that holds the point is it; their boxes also
    // end the figures below them.
    QList<QRectF> algorithms;
    for (const auto &caption : captions) {
        if (caption.kind != "algorithm") continue;
        const auto box = algorithmBox(pdf, page, layout, caption.line).adjusted(-4, -3, 4, 3);
        algorithms << box;
        if (!box.adjusted(-4, -4, 4, 4).contains(point)) continue;
        const auto head = pdf.getSelection(page, QPointF(caption.line.left() + 1, caption.line.center().y()),
                                 QPointF(caption.line.right() - 1, caption.line.center().y()))
                              .text()
                              .simplified();
        return {{"kind", "algorithm"}, {"label", caption.label}, {"page", page}, {"x", box.x()}, {"y", box.y()},
            {"width", box.width()}, {"height", box.height()}, {"caption", head}};
    }
    // Of the figures and tables whose area holds the point, the one whose caption is nearest on its side
    // (a figure's caption is below it, a table's above), then the smallest.
    QVariantMap best;
    qreal bestDistance = 0, bestArea = 0;
    for (const auto &caption : captions) {
        if (caption.kind == "algorithm") continue;
        auto found = floatIn(pdf, page, layout, captions, caption.line, caption.kind == "table");
        if (found.isEmpty()) continue;
        QRectF area(
            found["x"].toDouble(), found["y"].toDouble(), found["width"].toDouble(), found["height"].toDouble());
        const qreal captionTop = found["captionTop"].toDouble(), captionBottom = found["captionBottom"].toDouble();
        if (caption.kind == "figure")
            for (const auto &box : std::as_const(algorithms))
                if (box.bottom() <= captionTop && box.right() > area.left() && box.left() < area.right()
                    && box.bottom() > area.top())
                    area.setTop(box.bottom() + 4);
        if (!area.adjusted(-4, -4, 4, 4).contains(point)) continue;
        const qreal distance = caption.kind == "figure" ? std::max<qreal>(0, captionTop - point.y())
                                                        : std::max<qreal>(0, point.y() - captionBottom);
        const qreal size = area.width() * area.height();
        if (!best.isEmpty() && (distance > bestDistance || (distance == bestDistance && size >= bestArea))) continue;
        found.insert({{"kind", caption.kind}, {"label", caption.label}, {"page", page}, {"y", area.top()},
            {"height", area.height()}});
        best = found;
        bestDistance = distance;
        bestArea = size;
    }
    if (best.isEmpty()) return equationAround(pdf, page, point, layout);
    if (!best.contains("caption")) best.insert("caption", captionText(pdf, page, best));
    return best;
}

int ReferenceFinder::wordAt(const QUrl &source, int page, const QPointF &point, qreal tolerance)
{
    const int request = ++m_next;
    const auto path = source.toLocalFile();
    m_pool.start([this, request, path, page, point, tolerance] {
        QVariantMap word;
        QPdfDocument pdf;
        if (!path.isEmpty() && PdfAccess::load(pdf, path) == QPdfDocument::Error::None && page >= 0
            && page < pdf.pageCount()) {
            const int index = charAt(pdf, page, point, tolerance);
            if (index >= 0) {
                // The word: the characters around it up to spaces and punctuation that is not math.
                const int from = std::max(0, index - 24);
                const auto around = pdf.getSelectionAtIndex(page, from, 49).text();
                const auto boundary
                    = [](QChar c) { return c.isSpace() || QStringLiteral(",;:()[]{}\"'“”").contains(c); };
                qsizetype start = index - from, end = start + 1;
                if (start < around.size() && !boundary(around[start])) {
                    if (around[start].isLowSurrogate() && start > 0) --start;
                    while (start > 0 && !boundary(around[start - 1])) --start;
                    while (end < around.size() && !boundary(around[end])) ++end;
                    auto text = around.mid(start, end - start);
                    while (text.endsWith('.')) text.chop(1);
                    const auto glyph = around.mid(index - from, around[index - from].isHighSurrogate() ? 2 : 1);
                    const auto box
                        = pdf.getSelectionAtIndex(page, int(from + start), int(end - start)).boundingRectangle();
                    // Plain forms for matching: math letters (𝑥, 𝐩) as ordinary ones, no spaces.
                    const auto plain = [](const QString &value) {
                        return value.normalized(QString::NormalizationForm_KC).remove(QRegularExpression("\\s"));
                    };
                    word = {{"word", text}, {"glyph", glyph}, {"plainWord", plain(text)}, {"plainGlyph", plain(glyph)},
                        {"page", page}, {"x", box.x()}, {"y", box.y()}, {"width", box.width()},
                        {"height", box.height()}};
                }
            }
        }
        QMetaObject::invokeMethod(this, [this, request, word] { emit wordFound(request, word); }, Qt::QueuedConnection);
    });
    return request;
}
