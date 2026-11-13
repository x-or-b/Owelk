#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// LaTeX math drawn by MicroTeX (the renderer the desktop uses, `third_party/microtex`) with Core Graphics: black on
/// clear, as a template image the text's colour tints. Main thread only (MicroTeX is not thread-safe).
@interface OwelkMath : NSObject

/// The formula with `size` points to the em (display style when `display`), or nil when it cannot be read, a font is
/// missing, or it would be drawn enormous. `depth` is how far the picture reaches below the formula's baseline.
+ (nullable UIImage *)imageOfLatex:(NSString *)latex
                           display:(BOOL)display
                              size:(CGFloat)size
                             depth:(CGFloat *)depth;

@end

NS_ASSUME_NONNULL_END
