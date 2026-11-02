import SwiftUI
import Testing
@testable import ToyBoxUI

@Suite("App appearance")
struct AppAppearanceTests {
    @Test func persistedValuesAndSystemDefaultStayUnchanged() {
        #expect(AppAppearance.allCases.map(\.rawValue) == ["system", "light", "dark"])
        #expect(AppAppearance.allCases.map(\.id) == ["system", "light", "dark"])
        #expect(AppAppearance.allCases.map(\.title) == ["System", "Light", "Dark"])
        #expect(AppAppearance.system.colorScheme == nil)
        #expect(AppAppearance.light.colorScheme == .light)
        #expect(AppAppearance.dark.colorScheme == .dark)
    }
}
