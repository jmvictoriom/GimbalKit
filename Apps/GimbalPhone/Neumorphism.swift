import GimbalHostSupport
import GimbalKit
import SwiftUI

struct NeuPalette {
    let scheme: ColorScheme
    var background: Color { Color(hex: scheme == .dark ? 0x2B2F36 : 0xE6E9EF) }
    var darkShadow: Color { Color(hex: scheme == .dark ? 0x1F2227 : 0xA3B1C6) }
    var lightShadow: Color { Color(hex: scheme == .dark ? 0x373C45 : 0xFFFFFF) }
    var text: Color { Color(hex: scheme == .dark ? 0xE6E9EF : 0x3D4663) }
    // WCAG: 5,21:1 en claro y 7,42:1 en oscuro sobre la superficie.
    var secondary: Color { Color(hex: scheme == .dark ? 0xB8C1D2 : 0x536078) }
    static let violet = Color(hex: 0x7C3AED)
    static let sky = Color(hex: 0x0EA5E9)
    static let orange = Color(hex: 0xFF8A3D)
    static let red = Color(hex: 0xE5484D)
    static let green = Color(hex: 0x2FB67C)
    static let gradient = LinearGradient(colors: [violet, sky], startPoint: .topLeading, endPoint: .bottomTrailing)
}

private extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 255) / 255,
                  green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, opacity: 1)
    }
}

struct NeuSurface: View {
    @Environment(\.colorScheme) private var scheme
    var inset = false
    var radius: CGFloat = 24
    var danger = false

    var body: some View {
        let palette = NeuPalette(scheme: scheme)
        let fill = danger ? NeuPalette.red : palette.background
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if inset {
            shape.fill(fill
                .shadow(.inner(color: palette.darkShadow.opacity(0.85), radius: 6, x: 4, y: 4))
                .shadow(.inner(color: palette.lightShadow.opacity(0.9), radius: 6, x: -4, y: -4)))
        } else {
            shape.fill(fill)
                .shadow(color: palette.darkShadow.opacity(0.65), radius: 9, x: 6, y: 6)
                .shadow(color: palette.lightShadow.opacity(0.85), radius: 9, x: -6, y: -6)
        }
    }
}

struct NeuCard<Content: View>: View {
    private let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        content.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(NeuSurface())
    }
}

struct NeuInset<Content: View>: View {
    var padding: CGFloat
    private let content: Content
    init(padding: CGFloat = 14, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }
    var body: some View {
        content.padding(padding).background(NeuSurface(inset: true, radius: 18))
    }
}

struct NeuButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var enabled
    var danger = false

    func makeBody(configuration: Configuration) -> some View {
        let palette = NeuPalette(scheme: scheme)
        configuration.label
            .font(.body.weight(.semibold))
            .padding(.horizontal, 16).padding(.vertical, 12)
            .frame(minWidth: 44, minHeight: 44)
            .foregroundStyle(danger ? Color(hex: 0x2D0C11) : palette.text)
            .background(NeuSurface(inset: configuration.isPressed || !enabled, radius: 18, danger: danger))
            .overlay {
                if !enabled {
                    RoundedRectangle(cornerRadius: 18).strokeBorder(palette.secondary, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct NeuToggleStyle: ToggleStyle {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        let palette = NeuPalette(scheme: scheme)
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 12) {
                configuration.label.frame(maxWidth: .infinity, alignment: .leading)
                Text(configuration.isOn ? "Sí" : "No").font(.body.weight(.semibold))
                ZStack {
                    Capsule().fill(palette.background
                        .shadow(.inner(color: palette.darkShadow, radius: 4, x: 3, y: 3))
                        .shadow(.inner(color: palette.lightShadow, radius: 4, x: -3, y: -3)))
                    Circle().fill(configuration.isOn ? AnyShapeStyle(NeuPalette.gradient) : AnyShapeStyle(palette.secondary))
                        .frame(width: 24, height: 24).offset(x: configuration.isOn ? 10 : -10)
                }
                .frame(width: 52, height: 32).accessibilityHidden(true)
            }
            .foregroundStyle(palette.text).font(.body.weight(.semibold)).frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .accessibilityValue(configuration.isOn ? "Activada" : "Desactivada")
        .accessibilityAddTraits(.isToggle)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isOn)
    }
}

struct NeuChip: View {
    @Environment(\.colorScheme) private var scheme
    let text: String
    let symbol: String
    var accent: Color = NeuPalette.green

    var body: some View {
        let palette = NeuPalette(scheme: scheme)
        Label {
            Text(text).foregroundStyle(palette.text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(palette.text)
        }
        .font(.subheadline.weight(.semibold)).padding(.horizontal, 12).padding(.vertical, 8)
        .background(accent.opacity(scheme == .dark ? 0.10 : 0.06), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(accent, lineWidth: 1.5))
        .accessibilityElement(children: .combine)
    }
}

struct NeuGauge: View {
    @Environment(\.colorScheme) private var scheme
    @ScaledMetric(relativeTo: .body) private var gaugeHeight = 200
    let pose: Pose?
    private var validPose: Pose? { pose.flatMap { $0.isFinite ? $0 : nil } }

    var body: some View {
        let palette = NeuPalette(scheme: scheme)
        VStack(spacing: 16) {
            HStack(spacing: 16) {
                dial
                pitchBar
            }
            .frame(height: gaugeHeight).accessibilityHidden(true)
            if let pose = validPose {
                NeuInset {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 16) { angle("Yaw", pose.yaw); angle("Pitch", pose.pitch) }
                        VStack(alignment: .leading, spacing: 8) { angle("Yaw", pose.yaw); angle("Pitch", pose.pitch) }
                    }
                    .frame(maxWidth: .infinity)
                }
                Text("Roll \(pose.roll.formatted(.number.precision(.fractionLength(1))))°")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(palette.secondary)
                    .accessibilityLabel("Alabeo, \(pose.roll.formatted(.number.precision(.fractionLength(1)))) grados")
            } else {
                NeuChip(text: "Sin pose · no disponible o desactualizada", symbol: "questionmark.circle", accent: palette.secondary)
            }
        }
    }

    private func angle(_ name: String, _ value: Double) -> some View {
        Text("\(name) \(value.formatted(.number.precision(.fractionLength(1))))°")
            .font(.title3.weight(.semibold)).monospacedDigit()
            .accessibilityLabel("\(name == "Yaw" ? "Giro horizontal" : "Inclinación vertical"), \(value.formatted(.number.precision(.fractionLength(1)))) grados")
    }

    private var dial: some View {
        GeometryReader { geometry in
            let palette = NeuPalette(scheme: scheme)
            let size = min(geometry.size.width, geometry.size.height)
            let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
            let radius = size / 2 - 14
            ZStack {
                Circle().fill(palette.background
                    .shadow(.inner(color: palette.darkShadow, radius: 7, x: 5, y: 5))
                    .shadow(.inner(color: palette.lightShadow, radius: 7, x: -5, y: -5)))
                    .frame(width: size, height: size).position(center)
                Path { path in
                    for degrees in stride(from: 0, to: 360, by: 30) {
                        let radians = Double(degrees) * .pi / 180
                        path.move(to: CGPoint(x: center.x + sin(radians) * (radius - 9), y: center.y - cos(radians) * (radius - 9)))
                        path.addLine(to: CGPoint(x: center.x + sin(radians) * radius, y: center.y - cos(radians) * radius))
                    }
                }.stroke(palette.secondary, lineWidth: 2)
                if let pose = validPose {
                    let radians = pose.yaw.truncatingRemainder(dividingBy: 360) * .pi / 180
                    let end = CGPoint(x: center.x + sin(radians) * (radius - 18), y: center.y - cos(radians) * (radius - 18))
                    Path { path in path.move(to: center); path.addLine(to: end) }
                        .stroke(NeuPalette.gradient, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    Circle().fill(NeuPalette.orange).frame(width: 12, height: 12).position(end)
                }
                Circle().fill(validPose == nil ? palette.secondary : NeuPalette.orange)
                    .frame(width: 16, height: 16).position(center)
                Text("0°").font(.subheadline.weight(.semibold)).foregroundStyle(palette.secondary)
                    .position(x: center.x, y: center.y + radius / 2)
            }
        }
    }

    private var pitchBar: some View {
        let palette = NeuPalette(scheme: scheme)
        return VStack(spacing: 8) {
            Text("+45°")
            GeometryReader { geometry in
                ZStack(alignment: .top) {
                    Capsule().fill(palette.background
                        .shadow(.inner(color: palette.darkShadow, radius: 4, x: 3, y: 3))
                        .shadow(.inner(color: palette.lightShadow, radius: 4, x: -3, y: -3)))
                    if let point = ZoneMapProjection.point(for: validPose) {
                        Circle().fill(NeuPalette.orange).frame(width: 16, height: 16)
                            .offset(y: point.y * max(0, geometry.size.height - 16))
                    }
                }
            }.frame(width: 20)
            Text("−45°")
        }.font(.subheadline.weight(.semibold)).foregroundStyle(palette.secondary)
    }

}


/// Botón de PARADA: disco rojo con degradado y halo, sobre un botón neumórfico circular dentro de un pozo hundido.
/// Al pulsarlo se hunde (sombras invertidas), el halo se atenúa y el disco se encoge. Pensado para pulsarse sin mirar: 184 pt de diámetro.
struct NeuStopButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let palette = NeuPalette(scheme: scheme)
        let pressed = configuration.isPressed
        VStack(spacing: 16) {
            ZStack {
                // Pozo hundido que aloja el botón.
                Circle()
                    .fill(palette.background
                        .shadow(.inner(color: palette.darkShadow.opacity(0.85), radius: 9, x: 6, y: 6))
                        .shadow(.inner(color: palette.lightShadow.opacity(0.9), radius: 9, x: -6, y: -6)))
                    .frame(width: 184, height: 184)
                // Botón elevado; al pulsar se hunde.
                Group {
                    if pressed {
                        Circle().fill(palette.background
                            .shadow(.inner(color: palette.darkShadow.opacity(0.8), radius: 7, x: 5, y: 5))
                            .shadow(.inner(color: palette.lightShadow.opacity(0.85), radius: 7, x: -5, y: -5)))
                    } else {
                        Circle().fill(palette.background)
                            .shadow(color: palette.darkShadow.opacity(0.7), radius: 9, x: 6, y: 6)
                            .shadow(color: palette.lightShadow.opacity(0.9), radius: 9, x: -6, y: -6)
                    }
                }
                .frame(width: 144, height: 144)
                // Disco rojo con degradado, brillo superior y halo.
                Circle()
                    .fill(LinearGradient(colors: [Color(hex: 0xFF7A7F), Color(hex: 0xD8343B)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(Circle().strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.6), .clear], startPoint: .topLeading, endPoint: .center),
                        lineWidth: 2.5))
                    .frame(width: 108, height: 108)
                    .shadow(color: NeuPalette.red.opacity(pressed ? 0.22 : 0.55), radius: pressed ? 8 : 22, x: 0, y: pressed ? 2 : 9)
                    .scaleEffect(pressed && !reduceMotion ? 0.94 : 1)
                Image(systemName: "stop.fill")
                    .font(.system(size: 38, weight: .black))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    .scaleEffect(pressed && !reduceMotion ? 0.94 : 1)
            }
            configuration.label
                .font(.headline.weight(.heavy))
                .tracking(3)
                .foregroundStyle(palette.text)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: pressed)
    }
}
