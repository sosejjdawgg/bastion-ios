import Foundation
import SwiftSoup

public enum BastionCore {
    public static let version = "0.7.0"
    public static func soupWorks() -> Bool { (try? SwiftSoup.parse("<p>x</p>").text()) == "x" }
}
