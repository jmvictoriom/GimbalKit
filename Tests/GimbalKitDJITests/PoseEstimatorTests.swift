import Testing
import GimbalKit
@testable import GimbalKitDJI

private func attitude(_ hex: String) -> Quaternion {
    guard case let .attitude(q)? = OMTelemetry.decode(frame(hex)) else { fatalError("trama sin orientación") }
    return q
}

@Test func firstOrientationBecomesTheZeroReference() {
    var estimator = OMPoseEstimator()
    #expect(estimator.pose == nil)
    let pose = estimator.update(attitude(Real.yawA))
    #expect(abs(pose.yaw) < 1e-9 && abs(pose.pitch) < 1e-9 && abs(pose.roll) < 1e-9)
}

@Test func realYawMoveMatchesMeasuredAngles() {
    var estimator = OMPoseEstimator()
    _ = estimator.update(attitude(Real.yawA))
    let pose = estimator.update(attitude(Real.yawB))
    #expect(abs(pose.yaw - 21.89) < 0.1)
    #expect(abs(pose.pitch - 0.21) < 0.1)
    #expect(abs(pose.roll - 0.29) < 0.1)
    #expect(estimator.pose == pose)
}

@Test func realPitchMoveMatchesMeasuredAnglesWithFlippedSign() {
    var estimator = OMPoseEstimator()
    _ = estimator.update(attitude(Real.pitchA))
    let pose = estimator.update(attitude(Real.pitchB))
    #expect(abs(pose.yaw - (-0.01)) < 0.1)
    #expect(abs(pose.pitch - 21.93) < 0.1)
    #expect(abs(pose.roll - (-0.01)) < 0.1)
}

@Test func zeroTakesTheNextOrientationAsNewReference() {
    var estimator = OMPoseEstimator()
    _ = estimator.update(attitude(Real.yawA))
    _ = estimator.update(attitude(Real.yawB))
    estimator.zero()
    #expect(estimator.pose == nil)
    let pose = estimator.update(attitude(Real.yawB))
    #expect(abs(pose.yaw) < 1e-9)
}

@Test func gimbalLockNeverProducesNaN() throws {
    // Rotación de 90° alrededor de X respecto a la identidad: pitch en el límite de asin.
    let s = (0.5).squareRoot()
    var estimator = OMPoseEstimator()
    _ = estimator.update(Quaternion(x: 0, y: 0, z: 0, w: 1))
    let pose = estimator.update(Quaternion(x: s, y: 0, z: 0, w: s))
    #expect(pose.yaw.isFinite && pose.pitch.isFinite && pose.roll.isFinite)
    #expect(abs(abs(pose.pitch) - 90) < 0.5)
}
