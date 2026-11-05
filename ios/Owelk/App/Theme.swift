import SwiftUI
import UIKit

/// Owelk's look: neutral grays, with the accent (the asset catalog's AccentColor, Owelk blue) only for state and
/// emphasis: selection, the primary button, focus, progress and search matches.
enum Theme {
    static let accent = Color("AccentColor")
    static let accentUI = UIColor(named: "AccentColor") ?? .systemBlue
}
