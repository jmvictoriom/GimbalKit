#if os(iOS)
import AppIntents
import GimbalHostSupport
import GimbalKit
import GimbalKitMCP

public struct GimbalKitIntentsPackage: AppIntentsPackage {
    public static var includedPackages: [any AppIntentsPackage.Type] { [] }
}

public struct ZoneEntity: AppEntity, Identifiable {
    public static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Zona")
    public static let defaultQuery = ZoneEntityQuery()
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

public struct ZoneEntityQuery: EntityQuery {
    public init() {}

    public func entities(for identifiers: [String]) async throws -> [ZoneEntity] {
        let zones = try await ZoneStore().load()
        return zones
            .filter { !$0.forbidden && identifiers.contains($0.name) }
            .map { ZoneEntity(id: $0.name, name: $0.name) }
    }

    public func suggestedEntities() async throws -> [ZoneEntity] {
        try await ZoneStore().load()
            .filter { !$0.forbidden }
            .map { ZoneEntity(id: $0.name, name: $0.name) }
    }
}

public struct LookAtZoneIntent: AppIntent {
    public init() {}
    public static let title: LocalizedStringResource = "Mirar a zona"
    public static let description = IntentDescription("Mueve el estabilizador a una zona guardada.")
    public static let openAppWhenRun = false
    @Parameter(title: "Zona") public var zone: ZoneEntity

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let environment = PhoneHostEnvironment.shared
        _ = try await GimbalIntentActionService.look(
            zone: zone.name,
            runtime: environment.runtime,
            waitUntilConnected: { try await environment.waitUntilConnected(timeout: 10) }
        )
        return .result(dialog: "Mirando a \(zone.name).")
    }
}

public struct StopGimbalIntent: AppIntent {
    public init() {}
    public static let title: LocalizedStringResource = "Parar"
    public static let description = IntentDescription("Detiene el estabilizador.")
    public static let openAppWhenRun = false

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        await GimbalIntentActionService.stop(runtime: PhoneHostEnvironment.shared.runtime)
        return .result(dialog: "Estabilizador parado.")
    }
}

public struct GimbalStatusIntent: AppIntent {
    public init() {}
    public static let title: LocalizedStringResource = "Estado"
    public static let description = IntentDescription("Lee conexión, batería y pose.")
    public static let openAppWhenRun = false

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let status = try await GimbalIntentActionService.status(runtime: PhoneHostEnvironment.shared.runtime)
        let text = GimbalIntentActionService.statusSummary(status)
        return .result(dialog: IntentDialog(stringLiteral: text))
    }
}

public struct SaveZoneHereIntent: AppIntent {
    public init() {}
    public static let title: LocalizedStringResource = "Guardar zona aquí"
    public static let description = IntentDescription("Guarda la pose actual tras confirmación humana.")
    public static let openAppWhenRun = true
    @Parameter(title: "Nombre de la zona") public var name: String

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let environment = PhoneHostEnvironment.shared
        try await GimbalIntentActionService.saveZone(
            name: name,
            runtime: environment.runtime,
            confirm: { draft in
                let yaw = draft.pose.yaw.formatted(.number.precision(.fractionLength(1)))
                let pitch = draft.pose.pitch.formatted(.number.precision(.fractionLength(1)))
                try await self.requestConfirmation(
                    result: .result(dialog: "¿Guardar \(draft.zone.name) en yaw \(yaw)° y pitch \(pitch)°?"),
                    confirmationActionName: .create,
                    showPrompt: true
                )
            }
        )
        return .result(dialog: "Zona guardada.")
    }
}

public struct GimbalShortcuts: AppShortcutsProvider {
    public static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: LookAtZoneIntent(),
            phrases: ["Mira a \(\.$zone) con \(.applicationName)"],
            shortTitle: "Mirar a zona",
            systemImageName: "viewfinder"
        )
        AppShortcut(
            intent: StopGimbalIntent(),
            phrases: ["Para el estabilizador con \(.applicationName)"],
            shortTitle: "Parar",
            systemImageName: "stop.fill"
        )
        AppShortcut(
            intent: GimbalStatusIntent(),
            phrases: ["Estado del estabilizador con \(.applicationName)"],
            shortTitle: "Estado",
            systemImageName: "battery.100"
        )
        AppShortcut(
            intent: SaveZoneHereIntent(),
            phrases: ["Guarda esta zona con \(.applicationName)"],
            shortTitle: "Guardar zona",
            systemImageName: "mappin"
        )
    }
}
#endif
