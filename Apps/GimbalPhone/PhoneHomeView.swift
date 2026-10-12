import Observation
import GimbalHostSupport
import GimbalKit
import SwiftUI

@MainActor
struct PhoneHomeView: View {
    @Bindable var model: PhoneHostModel
    @State private var zoneName = ""
    @State private var forbidden = false
    @State private var zoneConfirmationDraft: ZoneDraft?
    @State private var showZoneConfirmation = false
    @State private var showReferenceConfirmation = false

    var body: some View {
        NavigationStack {
            List {
                Section("Estabilizador") {
                    Label(model.status.connected ? "Conectada" : "Desconectada · reconectando",
                          systemImage: model.status.connected ? "checkmark.circle.fill" : "bolt.horizontal.circle")
                    if let battery = model.status.battery {
                        Text("Batería: \(battery.percent)%\(battery.charging ? " · cargando" : "")")
                    }
                    if let pose = model.status.pose {
                        Text("Yaw \(pose.yaw.formatted(.number.precision(.fractionLength(1))))° · Pitch \(pose.pitch.formatted(.number.precision(.fractionLength(1))))° · Roll \(pose.roll.formatted(.number.precision(.fractionLength(1))))°")
                    } else {
                        Text("Pose no disponible o desactualizada")
                    }
                    if let lease = model.status.lease {
                        Label("Agente con control de \(lease.zone)", systemImage: "eye.fill")
                            .foregroundStyle(.orange)
                    }
                    Button(role: .destructive) {
                        Task { await model.humanStop() }
                    } label: {
                        Label("PARADA", systemImage: "stop.fill")
                            .font(.title2.bold())
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .accessibilityHint("Detiene el estabilizador sin esperar una conexión nueva")
                }

                Section("Zonas") {
                    ForEach(model.zones, id: \.name) { zone in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(zone.name)
                                if zone.forbidden { Text("Prohibida").font(.caption).foregroundStyle(.red) }
                            }
                            Spacer()
                            if !zone.forbidden {
                                Button("Mirar") { Task { await model.look(zone: zone.name) } }
                                    .disabled(!model.status.connected)
                            }
                        }
                    }
                    TextField("Nombre de zona", text: $zoneName)
                    Toggle("Zona prohibida", isOn: $forbidden)
                    Button("Guardar zona aquí") {
                        Task {
                            zoneConfirmationDraft = await model.prepareZone(name: zoneName, forbidden: forbidden)
                            showZoneConfirmation = zoneConfirmationDraft != nil
                        }
                    }
                    .disabled(!model.status.connected || model.status.pose == nil ||
                              zoneName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if !model.status.referenceReady && !model.zones.isEmpty {
                    Section("Referencia") {
                        Text("Comprueba físicamente la referencia y todas las zonas antes de confirmarla.")
                        Button("Confirmar referencia") {
                            Task {
                                await model.prepareReference()
                                showReferenceConfirmation = model.referenceDraft != nil
                            }
                        }
                        .disabled(!model.status.connected || model.status.pose == nil)
                    }
                }

                if let error = model.errorMessage {
                    Section("Aviso") { Text(error).foregroundStyle(.red) }
                }

                Section("Registro") {
                    Text(model.audit.suffix(20).map { "\($0.date.formatted()) · \($0.event)" }
                        .joined(separator: "\n"))
                        .font(.caption)
                }
            }
            .navigationTitle("GimbalKit")
            .alert("Guardar zona aquí", isPresented: $showZoneConfirmation) {
                Button("Guardar") {
                    guard let draft = zoneConfirmationDraft else { return }
                    Task {
                        await model.confirmZone(draft)
                        zoneConfirmationDraft = nil
                        zoneName = ""
                    }
                }
                Button("Cancelar", role: .cancel) {
                    model.cancelZone(zoneConfirmationDraft)
                    zoneConfirmationDraft = nil
                }
            } message: {
                if let draft = zoneConfirmationDraft {
                    Text("Crear \(draft.zone.name) alrededor de yaw \(draft.pose.yaw.formatted(.number.precision(.fractionLength(1))))° y pitch \(draft.pose.pitch.formatted(.number.precision(.fractionLength(1))))°.")
                }
            }
            .alert("Confirmar referencia", isPresented: $showReferenceConfirmation) {
                Button("He comprobado las zonas") { Task { await model.confirmReference() } }
                Button("Cancelar", role: .cancel) { model.cancelReference() }
            } message: {
                Text("Confirma solo después de comprobar físicamente la orientación inicial y las zonas guardadas.")
            }
        }
    }
}
