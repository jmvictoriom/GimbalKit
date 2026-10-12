/// La lógica decide el feedback; UIKit queda en la app y las pruebas inyectan un falso.
@MainActor
public protocol Haptics {
    func success()
    func warning()
    func stopImpact()
}

public struct SilentHaptics: Haptics {
    public init() {}
    public func success() {}
    public func warning() {}
    public func stopImpact() {}
}
