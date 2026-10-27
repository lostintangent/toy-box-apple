import Testing
import ToyBoxMobileIntegrations

struct MobileSharedContainerTests {
    @Test func allMobileComponentsUseTheExplicitMobileAppGroup() {
        #expect(MobileSharedContainer.identifier == "group.dev.toybox.mobile")
    }
}
