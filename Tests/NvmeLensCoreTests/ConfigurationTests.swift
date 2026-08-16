import Testing

@testable import NvmeLensCore

@Suite("TOMLLite")
struct TOMLLiteTests {
    @Test("sections, keys and the three value kinds")
    func basics() throws {
        let table = try TOMLLite.parse(
            """
            [temperature]
            warning_celsius = 78
            enabled = true
            label = "hotspot"
            """)
        #expect(table["temperature"]?["warning_celsius"]?.integerValue == 78)
        #expect(table["temperature"]?["enabled"]?.booleanValue == true)
        #expect(table["temperature"]?["label"]?.stringValue == "hotspot")
    }

    @Test("comments are stripped, including trailing ones")
    func comments() throws {
        let table = try TOMLLite.parse(
            """
            # leading comment
            [a]
            x = 1  # trailing comment
            """)
        #expect(table["a"]?["x"]?.integerValue == 1)
    }

    @Test("a '#' inside a quoted string is not a comment")
    func hashInsideString() throws {
        let table = try TOMLLite.parse(
            """
            [a]
            colour = "#ff0000"
            """)
        #expect(table["a"]?["colour"]?.stringValue == "#ff0000")
    }

    /// A threshold silently dropped is a monitor that silently stops warning, so
    /// anything outside the supported subset must fail loudly.
    @Test("an unsupported value type is rejected rather than ignored")
    func rejectsUnsupportedValue() {
        #expect(throws: (any Error).self) {
            try TOMLLite.parse(
                """
                [a]
                x = 1.5
                """)
        }
        #expect(throws: (any Error).self) {
            try TOMLLite.parse(
                """
                [a]
                x = [1, 2]
                """)
        }
    }

    @Test("a malformed line is rejected")
    func rejectsMalformedLine() {
        #expect(throws: (any Error).self) { try TOMLLite.parse("[a]\nnot a pair") }
        #expect(throws: (any Error).self) { try TOMLLite.parse("[unclosed\nx = 1") }
    }

    @Test("a duplicated key is rejected rather than last-one-wins")
    func rejectsDuplicateKey() {
        #expect(throws: (any Error).self) {
            try TOMLLite.parse(
                """
                [a]
                x = 1
                x = 2
                """)
        }
    }
}

@Suite("Configuration")
struct ConfigurationTests {
    /// The idle hotspot measured on real hardware is 69 C; a default that fires
    /// there would be turned off within a day.
    @Test("defaults sit above a realistic idle hotspot and below the drive's own threshold")
    func defaultsAreLivable() {
        let config = Configuration()
        #expect(config.temperature.warningCelsius > 69)
        #expect(config.temperature.warningCelsius < 84)
        #expect(config.temperature.criticalCelsius > config.temperature.warningCelsius)
        #expect(config.temperature.sustainedMinutes > 0)
    }

    @Test("values from the file override the defaults")
    func overridesDefaults() throws {
        let config = try Configuration(
            toml: """
                [temperature]
                warning_celsius = 65
                sustained_minutes = 2

                [anomaly]
                power_cycles_per_hour_warning = 5

                [sampling]
                temperature_interval_seconds = 30
                """)
        #expect(config.temperature.warningCelsius == 65)
        #expect(config.temperature.sustainedMinutes == 2)
        #expect(config.anomaly.powerCyclesPerHourWarning == 5)
        #expect(config.sampling.temperatureIntervalSeconds == 30)
        // Untouched keys keep their defaults.
        #expect(config.temperature.criticalCelsius == Configuration().temperature.criticalCelsius)
    }

    @Test("an empty file yields the defaults")
    func emptyFile() throws {
        #expect(try Configuration(toml: "") == Configuration())
    }

    /// Falling back to defaults on a malformed file would mean the operator's
    /// thresholds stopped applying with nobody told.
    @Test("a malformed file is an error, not a silent fallback")
    func malformedFileThrows() {
        #expect(throws: (any Error).self) { try Configuration(toml: "[temperature\nx = 1") }
    }
}
