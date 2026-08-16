import Testing

@testable import NvmeLensCore

@Suite("Version")
struct VersionTests {
    @Test("a substituted version is reported as-is")
    func substitutedVersion() {
        #expect(Version.resolve(bundleValue: "1.2.3") == "1.2.3")
    }

    @Test("surrounding whitespace is trimmed")
    func trimsWhitespace() {
        #expect(Version.resolve(bundleValue: "  1.2.3\n") == "1.2.3")
    }

    @Test("a missing bundle value falls back to the development marker")
    func missingValueFallsBack() {
        #expect(Version.resolve(bundleValue: nil) == Version.developmentFallback)
    }

    @Test("an empty bundle value falls back rather than reporting nothing")
    func emptyValueFallsBack() {
        #expect(Version.resolve(bundleValue: "   ") == Version.developmentFallback)
    }

    @Test("an unsubstituted Makefile placeholder never reaches the user")
    func placeholderFallsBack() {
        #expect(Version.resolve(bundleValue: "${VERSION}") == Version.developmentFallback)
    }
}
