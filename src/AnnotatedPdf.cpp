#include "AnnotatedPdf.h"

#ifdef OWELK_HAVE_QPDF
#include <QColor>
#include <QDateTime>
#include <QFileInfo>
#include <QImage>
#include <QUrl>
#include <qpdf/QPDF.hh>
#include <qpdf/QPDFObjectHandle.hh>
#include <qpdf/QPDFPageDocumentHelper.hh>
#include <qpdf/QPDFPageObjectHelper.hh>
#include <qpdf/QPDFWriter.hh>
#include <cmath>

namespace {
using Handle = QPDFObjectHandle;

// Page geometry: the crop box and rotation, to turn Owelk's page-relative coordinates (as shown, from
// the top left) into PDF user space.
struct Page {
    double left = 0, bottom = 0, width = 0, height = 0;
    int rotation = 0;
    // A point in shown-page fractions → PDF space.
    std::pair<double, double> point(double fx, double fy) const
    {
        const bool turned = rotation == 90 || rotation == 270;
        const double X = fx * (turned ? height : width), Y = fy * (turned ? width : height);
        double u = X, v = height - Y;
        if (rotation == 90)
            u = Y, v = X;
        else if (rotation == 180)
            u = width - X, v = Y;
        else if (rotation == 270)
            u = width - Y, v = height - X;
        return {left + u, bottom + v};
    }
    // A shown rectangle → its PDF bounds (llx, lly, urx, ury).
    std::array<double, 4> rect(double x, double y, double w, double h) const
    {
        const auto a = point(x, y), b = point(x + w, y + h);
        return {std::min(a.first, b.first), std::min(a.second, b.second), std::max(a.first, b.first),
            std::max(a.second, b.second)};
    }
};

Handle real(double value)
{
    return Handle::newReal(value, 3);
}
Handle numbers(std::initializer_list<double> values)
{
    auto array = Handle::newArray();
    for (const auto v : values) array.appendItem(real(v));
    return array;
}
Handle rectangle(const std::array<double, 4> &r)
{
    return numbers({r[0], r[1], r[2], r[3]});
}
Handle colorArray(const QColor &color)
{
    return numbers({color.redF(), color.greenF(), color.blueF()});
}
std::string number(double value)
{
    return QString::number(value, 'f', 3).toStdString();
}
std::string rgb(const QColor &color)
{
    return number(color.redF()) + " " + number(color.greenF()) + " " + number(color.blueF());
}

// An appearance stream: what viewers draw for the annotation (pdfium needs one).
Handle appearance(QPDF &pdf, const std::array<double, 4> &bounds, const std::string &content,
    Handle resources = Handle::newDictionary())
{
    auto stream = Handle::newStream(&pdf, content);
    auto dict = stream.getDict();
    dict.replaceKey("/Type", Handle::newName("/XObject"));
    dict.replaceKey("/Subtype", Handle::newName("/Form"));
    dict.replaceKey("/BBox", rectangle(bounds));
    dict.replaceKey("/Resources", resources);
    auto states = Handle::newDictionary();
    states.replaceKey("/N", stream);
    return states;
}

Handle baseAnnotation(
    const char *subtype, const std::array<double, 4> &bounds, const QColor &color, const QString &body)
{
    auto annot = Handle::newDictionary();
    annot.replaceKey("/Type", Handle::newName("/Annot"));
    annot.replaceKey("/Subtype", Handle::newName(subtype));
    annot.replaceKey("/Rect", rectangle(bounds));
    annot.replaceKey("/C", colorArray(color));
    annot.replaceKey("/F", Handle::newInteger(4)); // Print
    annot.replaceKey("/T", Handle::newUnicodeString("Owelk"));
    annot.replaceKey(
        "/M", Handle::newString(QDateTime::currentDateTimeUtc().toString("'D:'yyyyMMddHHmmss'Z'").toStdString()));
    if (!body.isEmpty()) annot.replaceKey("/Contents", Handle::newUnicodeString(body.toStdString()));
    return annot;
}

// Text that the standard Helvetica (WinAnsi) can show; other scripts are kept in /Contents only.
std::string latin(const QString &text)
{
    std::string out;
    for (const auto c : text) {
        const auto code = c.unicode();
        if (code == '(' || code == ')' || code == '\\') out += '\\';
        out += code >= 32 && code < 256 ? char(code) : '?';
    }
    return out;
}
bool showable(const QString &text)
{
    return std::all_of(text.cbegin(), text.cend(), [](QChar c) { return c.unicode() < 256; });
}
}

namespace AnnotatedPdf {
bool available()
{
    return true;
}

QString write(const QString &source, const QString &target, const QVariantList &marks, const QString &password)
{
    if (QFileInfo(source).canonicalFilePath() == QFileInfo(target).absoluteFilePath())
        return "Choose a different file name.";
    try {
        QPDF pdf;
        pdf.setSuppressWarnings(true);
        pdf.processFile(source.toLocal8Bit().constData(), password.isEmpty() ? nullptr : password.toUtf8().constData());
        auto pages = QPDFPageDocumentHelper(pdf).getAllPages();
        int written = 0;
        for (const auto &value : marks) {
            const auto mark = value.toMap();
            const int index = mark.value("page").toInt();
            if (index < 0 || index >= int(pages.size())) continue;
            auto &helper = pages[size_t(index)];
            auto pageObject = helper.getObjectHandle();
            const auto box = helper.getCropBox().getArrayAsRectangle();
            auto rotate = helper.getAttribute("/Rotate", false); // not const: older qpdf (Ubuntu) has non-const getters
            Page page{box.llx, box.lly, box.urx - box.llx, box.ury - box.lly,
                ((rotate.isInteger() ? rotate.getIntValueAsInt() : 0) % 360 + 360) % 360};
            const QColor color(mark.value("color").toString());
            const auto kind = mark.value("kind").toString(), body = mark.value("body").toString();
            const auto rects = mark.value("rectangles").toList();
            if (rects.isEmpty()) continue;
            QList<std::array<double, 4>> boxes;
            for (const auto &r : rects) {
                const auto m = r.toMap();
                boxes << page.rect(m["x"].toDouble(), m["y"].toDouble(), m["width"].toDouble(), m["height"].toDouble());
            }
            std::array<double, 4> all = boxes.first();
            for (const auto &b : boxes)
                all = {std::min(all[0], b[0]), std::min(all[1], b[1]), std::max(all[2], b[2]), std::max(all[3], b[3])};
            Handle annot;
            if (kind == "highlight"
                || (kind == "comment" && rects.size() >= 1 && mark.value("text").toString().size())) {
                // Marked text: a highlight over each line, the comment as its note.
                annot = baseAnnotation("/Highlight", all, color, body);
                auto quads = Handle::newArray();
                std::string content = "q /GS0 gs " + rgb(color) + " rg\n";
                for (const auto &b : boxes) {
                    for (const auto v : {b[0], b[3], b[2], b[3], b[0], b[1], b[2], b[1]}) quads.appendItem(real(v));
                    content += number(b[0]) + " " + number(b[1]) + " " + number(b[2] - b[0]) + " " + number(b[3] - b[1])
                        + " re f\n";
                }
                content += "Q";
                annot.replaceKey("/QuadPoints", quads);
                annot.replaceKey("/CA", real(.4));
                auto graphics = Handle::newDictionary();
                auto state = Handle::newDictionary();
                state.replaceKey("/BM", Handle::newName("/Multiply"));
                state.replaceKey("/ca", real(.4));
                graphics.replaceKey("/GS0", state);
                auto resources = Handle::newDictionary();
                resources.replaceKey("/ExtGState", graphics);
                annot.replaceKey("/AP", appearance(pdf, all, content, resources));
            } else if (kind == "comment") {
                // A note on an area: the sticky-note icon at its top right.
                const std::array<double, 4> icon{all[2] - 18, all[3] - 18, all[2], all[3]};
                annot = baseAnnotation("/Text", icon, color, body);
                annot.replaceKey("/Name", Handle::newName("/Comment"));
                annot.replaceKey("/AP",
                    appearance(pdf, icon,
                        "q " + rgb(color) + " rg 0 0 0 RG 0.5 w " + number(icon[0] + 1) + " " + number(icon[1] + 1)
                            + " 16 16 re B Q"));
            } else if (kind == "text") {
                annot = baseAnnotation("/FreeText", all, color, body);
                annot.replaceKey("/DA", Handle::newString("/Helv 11 Tf " + rgb(color) + " rg"));
                auto fonts = Handle::newDictionary();
                auto helvetica = Handle::newDictionary();
                helvetica.replaceKey("/Type", Handle::newName("/Font"));
                helvetica.replaceKey("/Subtype", Handle::newName("/Type1"));
                helvetica.replaceKey("/BaseFont", Handle::newName("/Helvetica"));
                helvetica.replaceKey("/Encoding", Handle::newName("/WinAnsiEncoding"));
                fonts.replaceKey("/Helv", helvetica);
                auto resources = Handle::newDictionary();
                resources.replaceKey("/Font", fonts);
                std::string content = "q " + rgb(color) + " rg BT /Helv 11 Tf 13 TL " + number(all[0] + 2) + " "
                    + number(all[3] - 12) + " Td\n";
                // Scripts Helvetica cannot show stay readable in /Contents (editors show it).
                if (showable(body))
                    for (const auto &line : body.split('\n')) content += "(" + latin(line) + ") Tj T*\n";
                content += "ET Q";
                annot.replaceKey("/AP", appearance(pdf, all, content, resources));
            } else if (kind == "draw") {
                annot = baseAnnotation("/Ink", all, color, body);
                auto stroke = Handle::newArray();
                std::string path = "q " + rgb(color) + " RG 2 w 1 J 1 j\n";
                bool first = true;
                std::array<double, 4> reach = all;
                for (const auto &p : mark.value("drawing").toList()) {
                    const auto xy = p.toMap();
                    const auto [x, y] = page.point(xy["x"].toDouble(), xy["y"].toDouble());
                    stroke.appendItem(real(x));
                    stroke.appendItem(real(y));
                    path += number(x) + " " + number(y) + (first ? " m\n" : " l\n");
                    first = false;
                    reach = {std::min(reach[0], x - 2), std::min(reach[1], y - 2), std::max(reach[2], x + 2),
                        std::max(reach[3], y + 2)};
                }
                if (first) continue;
                path += "S Q";
                annot.replaceKey("/Rect", rectangle(reach));
                auto ink = Handle::newArray();
                ink.appendItem(stroke);
                annot.replaceKey("/InkList", ink);
                auto border = Handle::newDictionary();
                border.replaceKey("/W", Handle::newInteger(2));
                annot.replaceKey("/BS", border);
                annot.replaceKey("/AP", appearance(pdf, reach, path));
            } else if (kind == "image") {
                QImage image(mark.value("image").toUrl().toLocalFile());
                if (image.isNull()) continue;
                image = image.convertToFormat(QImage::Format_RGBA8888);
                std::string pixels, alpha;
                pixels.reserve(size_t(image.width() * image.height() * 3));
                for (int y = 0; y < image.height(); ++y) {
                    const auto *line = image.constScanLine(y);
                    for (int x = 0; x < image.width(); ++x) {
                        pixels.append(reinterpret_cast<const char *>(line + x * 4), 3);
                        alpha += char(line[x * 4 + 3]);
                    }
                }
                const auto picture = [&](const std::string &data, const char *space) {
                    auto stream = Handle::newStream(&pdf, data);
                    auto dict = stream.getDict();
                    dict.replaceKey("/Type", Handle::newName("/XObject"));
                    dict.replaceKey("/Subtype", Handle::newName("/Image"));
                    dict.replaceKey("/Width", Handle::newInteger(image.width()));
                    dict.replaceKey("/Height", Handle::newInteger(image.height()));
                    dict.replaceKey("/ColorSpace", Handle::newName(space));
                    dict.replaceKey("/BitsPerComponent", Handle::newInteger(8));
                    return stream;
                };
                auto xobject = picture(pixels, "/DeviceRGB");
                xobject.getDict().replaceKey("/SMask", picture(alpha, "/DeviceGray"));
                annot = baseAnnotation("/Stamp", all, color, body);
                auto images = Handle::newDictionary();
                images.replaceKey("/Im0", xobject);
                auto resources = Handle::newDictionary();
                resources.replaceKey("/XObject", images);
                annot.replaceKey("/AP",
                    appearance(pdf, all,
                        "q " + number(all[2] - all[0]) + " 0 0 " + number(all[3] - all[1]) + " " + number(all[0]) + " "
                            + number(all[1]) + " cm /Im0 Do Q",
                        resources));
            } else
                continue;
            annot.replaceKey("/P", pageObject);
            if (!pageObject.hasKey("/Annots") || !pageObject.getKey("/Annots").isArray())
                pageObject.replaceKey("/Annots", Handle::newArray());
            pageObject.getKey("/Annots").appendItem(pdf.makeIndirectObject(annot));
            ++written;
        }
        QPDFWriter writer(pdf, target.toLocal8Bit().constData());
        writer.write();
        return written || marks.isEmpty() ? QString() : QStringLiteral("No annotations could be written.");
    } catch (const std::exception &error) {
        return QStringLiteral("Cannot write the annotated PDF: %1").arg(QString::fromLocal8Bit(error.what()));
    }
}
}
#else
namespace AnnotatedPdf {
bool available()
{
    return false;
}
QString write(const QString &, const QString &, const QVariantList &, const QString &)
{
    return QStringLiteral("This build of Owelk has no PDF writer (qpdf).");
}
}
#endif
