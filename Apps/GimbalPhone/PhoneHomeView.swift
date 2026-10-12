import Observation
import GimbalHostSupport
import GimbalKit
import SwiftUI

@MainActor
struct PhoneHomeView: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var model: PhoneHostModel
    @State private var zoneName = ""
    @State private var forbidden = false
    @State private var zoneConfirmationDraft: ZoneDraft?
    @State private var showZoneConfirmation = false
    @State private var showReferenceConfirmation = false
    @State private var showDeleteConfirmation = false
    @State private var zoneToDelete: String?
    @State private var selectedZone: String?
    @State private var showLog = false

    private var palette: NeuPalette { NeuPalette(scheme: scheme) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 24) {
                    header
                    NeuCard {
                        VStack(alignment: .leading, spacing: 16) {
                            heading("Orientación", symbol: "scope")
                            NeuGauge(pose: model.status.pose)
                        }
                    }
                    stopCard
                    NeuCard {
                        VStack(alignment: .leading, spacing: 16) {
                            heading("Mapa de zonas", symbol: "map")
                            ZoneMapView(zones: model.zones, pose: model.status.pose, selectedZone: selectedZone) { name in
                                selectedZone = name
                                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                                    proxy.scrollTo(name, anchor: .center)
                                }
                            }
                        }
                    }
                    zonesCard
                    if !model.status.referenceReady && !model.zones.isEmpty { referenceCard }
                    warningsCard
                    logCard
                }
                .padding(20).frame(maxWidth: 620).frame(maxWidth: .infinity)
            }
            .background(palette.background.ignoresSafeArea())
            .foregroundStyle(palette.text)
            .font(.body.weight(.semibold))
            .buttonStyle(NeuButtonStyle())
            .scrollDismissesKeyboard(.interactively)
            .alert("Guardar zona aquí", isPresented: $showZoneConfirmation) {
                Button("Guardar") {
                    guard let draft = zoneConfirmationDraft else { return }
                    Task {
                        await model.confirmZone(draft)
                        zoneConfirmationDraft = nil
                        if model.zones.contains(where: { $0.name == draft.zone.name }) { zoneName = "" }
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
            .confirmationDialog("Borrar zona", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
                if let name = zoneToDelete {
                    Button("Borrar «\(name)»", role: .destructive) {
                        Task {
                            await model.deleteZone(name: name)
                            if !model.zones.contains(where: { $0.name == name }), selectedZone == name { selectedZone = nil }
                            zoneToDelete = nil
                        }
                    }
                }
                Button("Cancelar", role: .cancel) { zoneToDelete = nil }
            } message: {
                Text("Se eliminará «\(zoneToDelete ?? "")» de las zonas guardadas.")
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "camera.aperture").font(.largeTitle)
                    .foregroundStyle(NeuPalette.gradient).accessibilityHidden(true)
                Text("GimbalKit").font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { connection; battery }
                VStack(alignment: .leading, spacing: 12) { connection; battery }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var connection: some View {
        NeuChip(text: model.status.connected ? "Conectada" : "Reconectando…",
                symbol: model.status.connected ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath",
                accent: model.status.connected ? NeuPalette.green : palette.secondary)
    }

    @ViewBuilder private var battery: some View {
        if let battery = model.status.battery {
            Label("\(battery.percent)%\(battery.charging ? " · cargando" : "")",
                  systemImage: battery.charging ? "battery.100percent.bolt" : "battery.100percent")
                .font(.subheadline.weight(.semibold)).foregroundStyle(palette.secondary)
                .accessibilityLabel("Batería, \(battery.percent) por ciento\(battery.charging ? ", cargando" : "")")
        } else {
            Label("Batería sin datos", systemImage: "battery.0percent")
                .font(.subheadline.weight(.semibold)).foregroundStyle(palette.secondary)
        }
    }

    private var stopCard: some View {
        NeuCard {
            VStack(alignment: .leading, spacing: 14) {
                heading("Parada de seguridad", symbol: "hand.raised.fill")
                Button(role: .destructive) { Task { await model.humanStop() } } label: {
                    Label("PARADA", systemImage: "stop.fill")
                        .font(.title2.bold()).frame(maxWidth: .infinity).padding(.vertical, 8)
                }
                .buttonStyle(NeuButtonStyle(danger: true))
                .accessibilityHint("Detiene el estabilizador sin esperar una conexión nueva")
            }
        }
    }

    private var zonesCard: some View {
        NeuCard {
            VStack(alignment: .leading, spacing: 20) {
                heading("Zonas", symbol: "square.stack.3d.up")
                if model.zones.isEmpty {
                    Text("Todavía no hay zonas. Guarda una alrededor de la pose actual.")
                        .foregroundStyle(palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(model.zones, id: \.name) { zone in
                    zoneRow(zone).id(zone.name)
                }
                Divider().overlay(palette.secondary.opacity(0.3))
                NeuInset {
                    TextField("Nombre de zona", text: $zoneName)
                        .textInputAutocapitalization(.sentences).autocorrectionDisabled()
                        .accessibilityLabel("Nombre de la nueva zona")
                }
                Toggle("Zona prohibida", isOn: $forbidden).toggleStyle(NeuToggleStyle())
                Button {
                    Task {
                        zoneConfirmationDraft = await model.prepareZone(name: zoneName, forbidden: forbidden)
                        showZoneConfirmation = zoneConfirmationDraft != nil
                    }
                } label: {
                    Label("Guardar zona aquí", systemImage: "plus.circle").frame(maxWidth: .infinity)
                }
                .disabled(!model.status.connected || model.status.pose == nil || model.isLooking ||
                          zoneName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func zoneRow(_ zone: ZoneRecord) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(zone.name).font(.headline).fixedSize(horizontal: false, vertical: true)
            if zone.forbidden { NeuChip(text: "Prohibida", symbol: "nosign", accent: NeuPalette.red) }
            if selectedZone == zone.name {
                Label("Seleccionada en el mapa", systemImage: "checkmark.circle").font(.subheadline.weight(.semibold))
            }
            if model.lookOutcome.zone == zone.name { outcomeChip(model.lookOutcome) }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { zoneActions(zone) }
                VStack(alignment: .leading, spacing: 12) { zoneActions(zone) }
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(NeuSurface(inset: true, radius: 18))
        .overlay {
            if selectedZone == zone.name {
                RoundedRectangle(cornerRadius: 18).strokeBorder(palette.text, style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
            }
        }
    }

    @ViewBuilder private func zoneActions(_ zone: ZoneRecord) -> some View {
        if !zone.forbidden {
            Button { Task { await model.look(zone: zone.name) } } label: {
                Label(model.isLooking && model.status.lease?.zone == zone.name ? "Mirando…" : "Mirar", systemImage: "eye")
            }
            .disabled(!model.status.connected || model.isLooking)
            .accessibilityLabel("Mirar a \(zone.name)")
        }
        Spacer(minLength: 0)
        Button {
            zoneToDelete = zone.name
            showDeleteConfirmation = true
        } label: {
            Image(systemName: "trash").foregroundStyle(palette.text)
        }
        .disabled(model.isLooking)
        .accessibilityLabel("Borrar zona \(zone.name)")
        .accessibilityHint("Pide confirmación antes de borrar")
    }

    @ViewBuilder private func outcomeChip(_ outcome: LookOutcome) -> some View {
        switch outcome {
        case .arrived:
            NeuChip(text: "Llegada a la zona", symbol: "checkmark.circle.fill")
        case .alreadyInside:
            NeuChip(text: "Ya estabas dentro", symbol: "scope")
        case let .failed(_, reason):
            NeuChip(text: "No se pudo llegar: \(reason)", symbol: "exclamationmark.triangle.fill", accent: NeuPalette.red)
        case .idle:
            EmptyView()
        }
    }

    private var referenceCard: some View {
        NeuCard {
            VStack(alignment: .leading, spacing: 16) {
                heading("Referencia", symbol: "viewfinder")
                Text("Comprueba físicamente la referencia y todas las zonas antes de confirmarla.")
                    .foregroundStyle(palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Confirmar referencia") {
                    Task {
                        await model.prepareReference()
                        showReferenceConfirmation = model.referenceDraft != nil
                    }
                }
                .disabled(!model.status.connected || model.status.pose == nil || model.isLooking)
            }
        }
    }

    private var warningsCard: some View {
        NeuCard {
            VStack(alignment: .leading, spacing: 16) {
                heading("Avisos", symbol: "exclamationmark.bubble")
                if let error = model.errorMessage {
                    NeuChip(text: error, symbol: "exclamationmark.triangle.fill", accent: NeuPalette.red)
                }
                if let lease = model.status.lease {
                    Label("Agente con control de \(lease.zone)", systemImage: "eye.fill")
                }
                if model.errorMessage == nil && model.status.lease == nil {
                    Text("Sin avisos.").foregroundStyle(palette.secondary)
                }
            }
        }
    }

    private var logCard: some View {
        NeuCard {
            DisclosureGroup(isExpanded: $showLog) {
                Text(model.audit.suffix(20).map { "\($0.date.formatted()) · \($0.event)" }.joined(separator: "\n"))
                    .font(.subheadline.weight(.semibold)).foregroundStyle(palette.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 12).textSelection(.enabled)
            } label: { heading("Registro", symbol: "text.alignleft") }
            .tint(palette.text)
        }
    }

    private func heading(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol).font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
    }
}
