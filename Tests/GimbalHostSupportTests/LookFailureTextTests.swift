import Testing
import GimbalKit
@testable import GimbalHostSupport

@Suite struct LookFailureTextTests {
    @Test func navigationErrorsHaveSpecificReasons() {
        #expect(LookFailureText.reason(for: NavigationError.referenceRequired).contains("referencia"))
        #expect(LookFailureText.reason(for: NavigationError.unsafePath).contains("zona"))
        #expect(LookFailureText.reason(for: NavigationError.timeout).contains("tiempo"))
    }

    @Test func safetyViolationsNameTheZone() {
        #expect(LookFailureText.reason(for: SafetyViolation.outsideZone("frente")).contains("frente"))
        #expect(LookFailureText.reason(for: SafetyViolation.unknownZone("mesa")).contains("mesa"))
    }

    @Test func unknownErrorsFallBackToTheirDescription() {
        struct Boom: Error {}
        #expect(LookFailureText.reason(for: Boom()).contains("Boom"))
    }
}
