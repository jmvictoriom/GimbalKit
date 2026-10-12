import GimbalHostSupport
import GimbalKit
import SwiftUI

/// Seleccionar una zona solo resalta su fila. No hay controles de movimiento aquí.
struct ZoneMapView: View {
    @Environment(\.colorScheme) private var scheme
    let zones: [ZoneRecord]
    let pose: Pose?
    let selectedZone: String?
    let selectZone: (String) -> Void

    var body: some View {
        let palette = NeuPalette(scheme: scheme)
        VStack(spacing: 10) {
            Text("Pitch · +45°").frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityHidden(true)
            NeuInset(padding: 16) {
                GeometryReader { geometry in
                    ZStack {
                        ZoneMapGrid().stroke(palette.secondary.opacity(0.35), lineWidth: 1)
                            .accessibilityHidden(true)
                        ForEach(zones, id: \.name) { zone in
                            if let rect = ZoneMapProjection.rect(for: zone) {
                                zoneButton(zone, rect: rect, size: geometry.size)
                            }
                        }
                        Image(systemName: "plus").font(.body.bold()).foregroundStyle(palette.text)
                            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                            .accessibilityLabel("Referencia, cero grados de giro e inclinación")
                            .allowsHitTesting(false)
                        if let point = ZoneMapProjection.point(for: pose) {
                            Circle().fill(NeuPalette.orange)
                                .overlay(Circle().strokeBorder(palette.text, lineWidth: 2))
                                .frame(width: 14, height: 14)
                                .position(x: point.x * geometry.size.width, y: point.y * geometry.size.height)
                                .accessibilityLabel("Pose actual")
                                .accessibilityValue(poseDescription)
                                .allowsHitTesting(false)
                        }
                    }
                }
                .frame(height: 210)
            }
            HStack { Text("−90°"); Spacer(); Text("Yaw · 0°"); Spacer(); Text("+90°") }
                .accessibilityHidden(true)
            Text("Pitch · −45°").frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityHidden(true)
            Text("Toca una zona para resaltarla en la lista. La cruz es la referencia; el punto naranja, la pose actual.")
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            if ZoneMapProjection.point(for: pose) == nil {
                Label("Sin pose actual", systemImage: "questionmark.circle")
            }
            if zones.contains(where: \.forbidden) {
                Label("Rayado: zona prohibida", systemImage: "nosign")
            }
        }
        .font(.subheadline.weight(.semibold)).foregroundStyle(palette.secondary)
    }

    private var poseDescription: String {
        guard let pose, pose.isFinite else { return "Sin pose" }
        return "Giro \(pose.yaw.formatted(.number.precision(.fractionLength(1)))) grados, inclinación \(pose.pitch.formatted(.number.precision(.fractionLength(1)))) grados"
    }

    private func zoneButton(_ zone: ZoneRecord, rect: ZoneMapProjection.Rect, size: CGSize) -> some View {
        let palette = NeuPalette(scheme: scheme)
        let width = rect.width * size.width
        let height = rect.height * size.height
        let selected = selectedZone == zone.name
        return Button { selectZone(zone.name) } label: {
            ZStack {
                Rectangle().fill(zone.forbidden ? AnyShapeStyle(NeuPalette.red.opacity(0.18)) : AnyShapeStyle(NeuPalette.gradient.opacity(0.18)))
                if zone.forbidden {
                    ZoneHatching().stroke(NeuPalette.red, lineWidth: 1).clipShape(Rectangle())
                }
                Rectangle().strokeBorder(selected ? palette.text : (zone.forbidden ? NeuPalette.red : NeuPalette.violet),
                                         style: StrokeStyle(lineWidth: selected ? 3 : 1.5, dash: selected ? [5, 3] : []))
                Text(zone.name).font(.caption.weight(.semibold)).lineLimit(1)
                    .foregroundStyle(palette.text).padding(2)
                    .background(palette.background, in: RoundedRectangle(cornerRadius: 3))
                    .padding(3)
            }
            .frame(width: max(1, width), height: max(1, height))
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .position(x: (rect.origin.x + rect.width / 2) * size.width,
                  y: (rect.origin.y + rect.height / 2) * size.height)
        .accessibilityLabel("Zona \(zone.name)\(zone.forbidden ? ", prohibida" : "")")
        .accessibilityValue(selected ? "Seleccionada" : "Sin seleccionar")
        .accessibilityHint("Resalta esta zona en la lista")
    }
}

private struct ZoneMapGrid: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            for fraction in [0.0, 0.25, 0.5, 0.75, 1.0] {
                path.move(to: CGPoint(x: fraction * rect.width, y: 0))
                path.addLine(to: CGPoint(x: fraction * rect.width, y: rect.height))
                path.move(to: CGPoint(x: 0, y: fraction * rect.height))
                path.addLine(to: CGPoint(x: rect.width, y: fraction * rect.height))
            }
        }
    }
}

private struct ZoneHatching: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            for x in stride(from: -rect.height, through: rect.width, by: 8) {
                path.move(to: CGPoint(x: x, y: rect.height))
                path.addLine(to: CGPoint(x: x + rect.height, y: 0))
            }
        }
    }
}
