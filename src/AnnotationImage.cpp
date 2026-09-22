#include "AnnotationImage.h"
#include <QFileInfo>
#include <QImageReader>
#ifdef Q_OS_MACOS
#include <ImageIO/ImageIO.h>
#include <CoreGraphics/CoreGraphics.h>
#endif

QImage readAnnotationImage(const QUrl &source, QString *error)
{
    auto fail = [&](const QString &message) { if (error) *error = message; return QImage(); };
    if (!source.isLocalFile()) return fail("Choose a local image.");
    const auto suffix = QFileInfo(source.toLocalFile()).suffix().toLower();
    const bool heif = suffix == "heic" || suffix == "heif";
#ifdef Q_OS_MACOS
    if (heif) {
        const auto path = source.toLocalFile().toUtf8();
        auto url = CFURLCreateFromFileSystemRepresentation(nullptr,
            reinterpret_cast<const UInt8 *>(path.constData()), path.size(), false);
        auto decoder = url ? CGImageSourceCreateWithURL(url, nullptr) : nullptr;
        if (url) CFRelease(url);
        if (!decoder) return fail("Cannot decode this HEIC/HEIF image.");
        auto properties = CGImageSourceCopyPropertiesAtIndex(decoder, 0, nullptr);
        double width = 0, height = 0;
        if (properties) {
            const auto w = CFDictionaryGetValue(properties, kCGImagePropertyPixelWidth);
            const auto h = CFDictionaryGetValue(properties, kCGImagePropertyPixelHeight);
            if (w && CFGetTypeID(w) == CFNumberGetTypeID()) CFNumberGetValue(static_cast<CFNumberRef>(w), kCFNumberDoubleType, &width);
            if (h && CFGetTypeID(h) == CFNumberGetTypeID()) CFNumberGetValue(static_cast<CFNumberRef>(h), kCFNumberDoubleType, &height);
            CFRelease(properties);
        }
        if (!(width > 0 && height > 0 && width * height <= 25000000)) {
            CFRelease(decoder); return fail("Choose a local image up to 25 megapixels.");
        }
        int limit = 2048;
        auto number = CFNumberCreate(nullptr, kCFNumberIntType, &limit);
        const void *keys[] = {kCGImageSourceCreateThumbnailFromImageAlways,
            kCGImageSourceCreateThumbnailWithTransform, kCGImageSourceThumbnailMaxPixelSize};
        const void *values[] = {kCFBooleanTrue, kCFBooleanTrue, number};
        auto options = CFDictionaryCreate(nullptr, keys, values, 3,
            &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        auto cgImage = CGImageSourceCreateThumbnailAtIndex(decoder, 0, options);
        CFRelease(options); CFRelease(number); CFRelease(decoder);
        if (!cgImage) return fail("Cannot decode this HEIC/HEIF image.");
        QImage pixels(int(CGImageGetWidth(cgImage)), int(CGImageGetHeight(cgImage)), QImage::Format_RGBA8888_Premultiplied);
        pixels.fill(Qt::transparent);
        auto space = CGColorSpaceCreateDeviceRGB();
        auto context = CGBitmapContextCreate(pixels.bits(), pixels.width(), pixels.height(), 8,
            pixels.bytesPerLine(), space, CGBitmapInfo(kCGImageAlphaPremultipliedLast) | kCGBitmapByteOrder32Big);
        CGColorSpaceRelease(space);
        if (!context) { CGImageRelease(cgImage); return fail("Cannot allocate the image preview."); }
        CGContextDrawImage(context, CGRectMake(0, 0, pixels.width(), pixels.height()), cgImage);
        CGContextRelease(context); CGImageRelease(cgImage);
        return pixels;
    }
#endif
    QImageReader reader(source.toLocalFile()); reader.setAutoTransform(true);
    const auto size = reader.size();
    if (!size.isValid()) return fail(heif ? "HEIC/HEIF decoding is unavailable on this system. Convert to PNG or JPEG first." : "Cannot read this image.");
    if (qint64(size.width()) * size.height() > 25000000) return fail("Choose a local image up to 25 megapixels.");
    if (qMax(size.width(), size.height()) > 2048) reader.setScaledSize(size.scaled(2048, 2048, Qt::KeepAspectRatio));
    auto pixels = reader.read();
    if (pixels.isNull()) return fail("Cannot decode this image: " + reader.errorString());
    return pixels;
}
