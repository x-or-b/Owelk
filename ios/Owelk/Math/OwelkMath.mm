#import "OwelkMath.h"

#import <CoreText/CoreText.h>

#include "graphic/graphic.h"
#include "latex.h"
#include "render.h"

#include <map>
#include <memory>
#include <string>

// MicroTeX's drawing back end for the iPad: Core Graphics and Core Text in place of the desktop's Qt one
// (`third_party/microtex/src/platform/qt`). MicroTeX lays formulas out y-down, as UIKit's image contexts are.

using namespace tex;

namespace {

/// Set when a formula needed a font or a glyph the iPad does not have: it is then shown as written.
bool missing = false;

CTFontRef withStyle(CTFontRef font, int style) {
    CTFontSymbolicTraits traits = 0;
    if (style & BOLD) traits |= kCTFontTraitBold;
    if (style & ITALIC) traits |= kCTFontTraitItalic;
    if (!font || !traits) return font ? (CTFontRef)CFRetain(font) : nullptr;
    CTFontRef styled = CTFontCreateCopyWithSymbolicTraits(font, 0, nullptr, traits, traits);
    return styled ?: (CTFontRef)CFRetain(font);
}

/// The TeX fonts MicroTeX names by file (`res/fonts/…`), read once.
CGFontRef fontFile(const std::string &file) {
    static std::map<std::string, CGFontRef> loaded;
    auto found = loaded.find(file);
    if (found != loaded.end()) return found->second;
    CGFontRef font = nullptr;
    if (CGDataProviderRef data = CGDataProviderCreateWithFilename(file.c_str())) {
        font = CGFontCreateWithDataProvider(data);
        CGDataProviderRelease(data);
    }
    loaded[file] = font;
    return font;
}

}  // namespace

class Font_cg : public Font {
public:
    CTFontRef ref;
    int style;
    float size;

    /// Takes over `font` (+1).
    Font_cg(CTFontRef font, int style, float size) : ref(font), style(style), size(size) {}

    ~Font_cg() override {
        if (ref) CFRelease(ref);
    }

    float getSize() const override { return size; }

    sptr<Font> deriveFont(int style) const override { return sptrOf<Font_cg>(withStyle(ref, style), style, size); }

    bool operator==(const Font &other) const override {
        const auto &font = static_cast<const Font_cg &>(other);
        if (size != font.size || style != font.style) return false;
        if (ref == font.ref) return true;
        return ref && font.ref && CFEqual(ref, font.ref);
    }

    bool operator!=(const Font &other) const override { return !(*this == other); }
};

Font *Font::create(const std::string &file, float size) {
    CGFontRef font = fontFile(file);
    if (!font) missing = true;
    return new Font_cg(font ? CTFontCreateWithGraphicsFont(font, size, nullptr, nullptr) : nullptr, PLAIN, size);
}

/// The reader's own fonts, for words in formulas (\text{…}, in any script).
sptr<Font> Font::_create(const std::string &name, int style, float size) {
    CTFontRef font;
    if (name == "Serif") {
        font = CTFontCreateWithName(CFSTR("TimesNewRomanPSMT"), size, nullptr);
    } else if (name == "Monospaced") {
        font = CTFontCreateWithName(CFSTR("Menlo-Regular"), size, nullptr);
    } else if (name == "SansSerif" || name.empty()) {
        font = CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, size, nullptr);
    } else {
        CFStringRef family = CFStringCreateWithCString(nullptr, name.c_str(), kCFStringEncodingUTF8);
        font = CTFontCreateWithName(family ?: CFSTR("TimesNewRomanPSMT"), size, nullptr);
        if (family) CFRelease(family);
    }
    CTFontRef styled = withStyle(font, style);
    if (font) CFRelease(font);
    return sptrOf<Font_cg>(styled, style, size);
}

namespace {

NSString *string(const std::wstring &text) {
    // wchar_t is UTF-32 on Apple platforms; some strings arrive with a 0 at the end.
    auto end = text.find(L'\0');
    auto length = end == std::wstring::npos ? text.size() : end;
    return [[NSString alloc] initWithBytes:text.data() length:length * sizeof(wchar_t)
                                  encoding:NSUTF32LittleEndianStringEncoding] ?: @"";
}

/// A line of text in a font, filled with the context's colour.
CTLineRef line(NSString *text, CTFontRef font) {
    NSDictionary *attributes = @{
        (id)kCTFontAttributeName: (__bridge id)font,
        (id)kCTForegroundColorFromContextAttributeName: @YES,
    };
    return CTLineCreateWithAttributedString(
        (__bridge CFAttributedStringRef)[[NSAttributedString alloc] initWithString:text attributes:attributes]);
}

/// Draws upright with its baseline at (x, y) in the y-down context.
void atBaseline(CGContextRef context, float x, float y, void (^draw)(void)) {
    CGContextSaveGState(context);
    CGContextTranslateCTM(context, x, y);
    CGContextScaleCTM(context, 1, -1);
    CGContextSetTextMatrix(context, CGAffineTransformIdentity);
    CGContextSetTextPosition(context, 0, 0);
    draw();
    CGContextRestoreGState(context);
}

}  // namespace

class TextLayout_cg : public TextLayout {
    CTLineRef _line;

public:
    TextLayout_cg(const std::wstring &text, const sptr<Font_cg> &font) {
        if (!font->ref) missing = true;
        _line = font->ref ? line(string(text), font->ref) : nullptr;
    }

    ~TextLayout_cg() {
        if (_line) CFRelease(_line);
    }

    void getBounds(tex::Rect &bounds) override {
        CGFloat ascent = 0, descent = 0;
        double width = _line ? CTLineGetTypographicBounds(_line, &ascent, &descent, nullptr) : 0;
        bounds = tex::Rect(0, -ascent, width, ascent + descent);
    }

    void draw(Graphics2D &g2, float x, float y) override;
};

sptr<TextLayout> TextLayout::create(const std::wstring &text, const sptr<Font> &font) {
    return sptrOf<TextLayout_cg>(text, std::static_pointer_cast<Font_cg>(font));
}

class Graphics2D_cg : public Graphics2D {
    CGContextRef _context;
    CGAffineTransform _initial;
    color _color = black;
    Stroke _stroke;
    const Font *_font = nullptr;
    float _sx = 1, _sy = 1;

    void path(CGPathDrawingMode mode, CGPathRef path) {
        CGContextAddPath(_context, path);
        CGContextDrawPath(_context, mode);
    }

public:
    explicit Graphics2D_cg(CGContextRef context) : _context(context), _initial(CGContextGetCTM(context)) {
        setColor(black);
        setStroke(Stroke());
    }

    CGContextRef context() const { return _context; }

    void setColor(color c) override {
        _color = c;
        const CGFloat channels[] = {color_r(c) / 255.0, color_g(c) / 255.0, color_b(c) / 255.0, color_a(c) / 255.0};
        CGContextSetRGBFillColor(_context, channels[0], channels[1], channels[2], channels[3]);
        CGContextSetRGBStrokeColor(_context, channels[0], channels[1], channels[2], channels[3]);
    }

    color getColor() const override { return _color; }

    void setStroke(const Stroke &s) override {
        _stroke = s;
        CGContextSetLineWidth(_context, s.lineWidth);
        CGContextSetLineCap(_context, s.cap == CAP_ROUND ? kCGLineCapRound
                                      : s.cap == CAP_SQUARE ? kCGLineCapSquare : kCGLineCapButt);
        CGContextSetLineJoin(_context, s.join == JOIN_ROUND ? kCGLineJoinRound
                                       : s.join == JOIN_BEVEL ? kCGLineJoinBevel : kCGLineJoinMiter);
        if (s.miterLimit > 0) CGContextSetMiterLimit(_context, s.miterLimit);
    }

    const Stroke &getStroke() const override { return _stroke; }

    void setStrokeWidth(float w) override {
        _stroke.lineWidth = w;
        CGContextSetLineWidth(_context, w);
    }

    const Font *getFont() const override { return _font; }

    void setFont(const Font *font) override { _font = font; }

    void translate(float dx, float dy) override { CGContextTranslateCTM(_context, dx, dy); }

    void scale(float sx, float sy) override {
        _sx *= sx;
        _sy *= sy;
        CGContextScaleCTM(_context, sx, sy);
    }

    void rotate(float angle) override { CGContextRotateCTM(_context, angle); }

    void rotate(float angle, float px, float py) override {
        CGContextTranslateCTM(_context, px, py);
        CGContextRotateCTM(_context, angle);
        CGContextTranslateCTM(_context, -px, -py);
    }

    void reset() override {
        CGContextConcatCTM(_context, CGAffineTransformInvert(CGContextGetCTM(_context)));
        CGContextConcatCTM(_context, _initial);
        _sx = _sy = 1;
    }

    float sx() const override { return _sx; }

    float sy() const override { return _sy; }

    void drawChar(wchar_t c, float x, float y) override {
        auto font = static_cast<const Font_cg *>(_font);
        UniChar units[2];
        CFIndex count = 1;
        if (c > 0xFFFF) {
            units[0] = (UniChar)(0xD800 + ((c - 0x10000) >> 10));
            units[1] = (UniChar)(0xDC00 + ((c - 0x10000) & 0x3FF));
            count = 2;
        } else {
            units[0] = (UniChar)c;
        }
        CGGlyph glyphs[2] = {0, 0};
        if (!font || !font->ref || !CTFontGetGlyphsForCharacters(font->ref, units, glyphs, count) || !glyphs[0]) {
            missing = true;
            return;
        }
        CGContextRef context = _context;
        CTFontRef ref = font->ref;
        const CGGlyph glyph = glyphs[0];
        atBaseline(context, x, y, ^{
            const CGPoint origin = CGPointZero;
            CTFontDrawGlyphs(ref, &glyph, &origin, 1, context);
        });
    }

    void drawText(const std::wstring &text, float x, float y) override {
        auto font = static_cast<const Font_cg *>(_font);
        if (!font || !font->ref) {
            missing = true;
            return;
        }
        CTLineRef drawn = line(string(text), font->ref);
        CGContextRef context = _context;
        atBaseline(context, x, y, ^{ CTLineDraw(drawn, context); });
        CFRelease(drawn);
    }

    void drawLine(float x1, float y1, float x2, float y2) override {
        CGContextBeginPath(_context);
        CGContextMoveToPoint(_context, x1, y1);
        CGContextAddLineToPoint(_context, x2, y2);
        CGContextStrokePath(_context);
    }

    void drawRect(float x, float y, float w, float h) override { CGContextStrokeRect(_context, CGRectMake(x, y, w, h)); }

    void fillRect(float x, float y, float w, float h) override { CGContextFillRect(_context, CGRectMake(x, y, w, h)); }

    void drawRoundRect(float x, float y, float w, float h, float rx, float ry) override {
        roundRect(kCGPathStroke, x, y, w, h, rx, ry);
    }

    void fillRoundRect(float x, float y, float w, float h, float rx, float ry) override {
        roundRect(kCGPathFill, x, y, w, h, rx, ry);
    }

private:
    void roundRect(CGPathDrawingMode mode, float x, float y, float w, float h, float rx, float ry) {
        if (w <= 0 || h <= 0) return;
        CGPathRef rounded = CGPathCreateWithRoundedRect(CGRectMake(x, y, w, h), MAX(0, MIN(rx, w / 2)),
                                                        MAX(0, MIN(ry, h / 2)), nullptr);
        path(mode, rounded);
        CGPathRelease(rounded);
    }
};

void TextLayout_cg::draw(Graphics2D &g2, float x, float y) {
    if (!_line) return;
    CGContextRef context = static_cast<Graphics2D_cg &>(g2).context();
    CTLineRef drawn = _line;
    atBaseline(context, x, y, ^{ CTLineDraw(drawn, context); });
}

@implementation OwelkMath

+ (UIImage *)imageOfLatex:(NSString *)latex display:(BOOL)display size:(CGFloat)size depth:(CGFloat *)depth {
    static const bool ready = [] {
        // The fonts are in the app as res/fonts/…, as MicroTeX names them.
        NSString *root = [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"res"];
        try {
            RES_BASE = root.fileSystemRepresentation;
            LaTeX::init(RES_BASE);
            return true;
        } catch (...) {
            return false;
        }
    }();
    NSString *formula = [latex stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!ready || formula.length == 0 || formula.length > 4000 || size <= 0) return nil;
    NSData *utf32 = [formula dataUsingEncoding:NSUTF32LittleEndianStringEncoding];
    // MicroTeX lays out in display style unless told otherwise; in the line, formulas stay as low as text.
    std::wstring text(display ? L"\\displaystyle " : L"\\textstyle ");
    text.append((const wchar_t *)utf32.bytes, utf32.length / sizeof(wchar_t));
    try {
        missing = false;
        std::unique_ptr<TeXRender> laid(LaTeX::parse(text, 100000, size, size / 3, black));
        if (!laid || missing) return nil;
        const int width = laid->getWidth(), height = laid->getHeight();
        // A formula that would be drawn enormous (\rule{9999cm}…, a runaway matrix) stays as its LaTeX.
        if (width <= 0 || height <= 0 || width > 4096 || height > 4096 || (long long)width * height > 4 * 1024 * 1024)
            return nil;
        const int pad = 1;  // Room for antialiased edges.
        UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
        format.opaque = NO;
        UIGraphicsImageRenderer *renderer =
            [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(width + 2 * pad, height + 2 * pad) format:format];
        __block bool failed = false;
        TeXRender *formulaBox = laid.get();
        UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
            Graphics2D_cg graphics(context.CGContext);
            try {
                formulaBox->draw(graphics, pad, pad);
            } catch (...) {
                failed = true;
            }
        }];
        if (failed || missing) return nil;
        if (depth) *depth = laid->getDepth() + pad;
        UIImage *template_ = [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        template_.accessibilityLabel = formula;
        return template_;
    } catch (...) {
        return nil;
    }
}

@end
