import Foundation
import Testing
@testable import MacState

@Test func glassPreferencesMigrateAndPersist() throws {
    let legacy = try JSONDecoder().decode(Settings.self, from: Data("{\"theme\":\"light\",\"menuColumnSpacing\":2}".utf8)).validated()
    #expect(legacy.glassOpacity == 1)
    #expect(!legacy.nativeGlassEnabled)
    #expect(legacy.theme == "light")
    #expect(legacy.menuColumnSpacing == 2)
    var changed = legacy
    changed.glassOpacity = 0.73
    changed.nativeGlassEnabled = true
    let restored = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(changed)).validated()
    #expect(restored.glassOpacity == 0.73)
    #expect(restored.nativeGlassEnabled)
    #expect(restored.theme == legacy.theme)
    #expect(restored.menuColumns == legacy.menuColumns)
}

@Test func glassPreferencesRejectInvalidOpacity() {
    var settings = Settings()
    for (value, expected) in [(-1.0, 0.0), (2.0, 1.0), (Double.nan, 1.0), (Double.infinity, 1.0)] {
        settings.glassOpacity = value
        #expect(settings.validated().glassOpacity == expected)
    }
}

@Test func existingGlassDensityIsPreservedButDesktopCaptureIsOptIn() throws {
    let old = try JSONDecoder().decode(Settings.self, from: Data(#"{"glassOpacity":0,"theme":"light","desktopLensEnabled":true}"#.utf8)).validated()
    #expect(old.glassOpacity == 0)
    #expect(!old.nativeGlassEnabled)
    #expect(Settings().glassOpacity == 1)
    #expect(!Settings().nativeGlassEnabled)
}
