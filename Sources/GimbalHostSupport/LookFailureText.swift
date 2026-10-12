import GimbalKit

/// Traduce un fallo de «mirar a zona» a un motivo legible para la persona (en vez de una frase genérica).
public enum LookFailureText {
    public static func reason(for error: any Error) -> String {
        if let navigation = error as? NavigationError {
            switch navigation {
            case .referenceRequired: return "falta confirmar la referencia (sección «Referencia»)."
            case .stalePose: return "la pose del estabilizador está desactualizada (¿llega la telemetría?)."
            case .timeout: return "se agotó el tiempo sin llegar; el navegador es lento, prueba con la Osmo más cerca del centro."
            case .unsafePath: return "el movimiento saldría de la zona o tocaría una zona prohibida; acerca la Osmo al centro de la zona."
            case .interrupted: return "interrumpido por una parada, un cambio de conexión o la referencia."
            case .busy: return "ya hay otra operación en curso."
            }
        }
        if let safety = error as? SafetyViolation {
            switch safety {
            case let .outsideZone(zone): return "la Osmo está fuera de la zona «\(zone)»: acércala a su centro (±10°) con el joystick."
            case let .unknownZone(zone): return "la zona «\(zone)» no existe."
            case let .forbiddenZone(zone): return "«\(zone)» es una zona prohibida."
            case .poseUnavailable: return "no hay pose del estabilizador todavía."
            case .noLease, .leaseExpired: return "el permiso de movimiento no está vigente."
            case let .busy(holder): return "otro control tiene el mando (\(holder))."
            case .speedTooHigh, .leaseTooLong, .invalidDuration, .invalidValue, .unsupported:
                return "la orden no cumple la política de seguridad (\(safety))."
            }
        }
        return "\(error)"
    }
}
