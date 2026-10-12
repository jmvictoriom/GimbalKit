import SwiftUI

struct PhoneSettingsView: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.openURL) private var openURL

    var body: some View {
        let palette = NeuPalette(scheme: scheme)
        ScrollView {
            NeuCard {
                VStack(alignment: .leading, spacing: 16) {
                    Label("Accesos rápidos", systemImage: "bolt.fill")
                        .font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
                    Text("En Atajos, crea un atajo con la acción GimbalKit → Parar.")
                    Text("Botón de acción: Ajustes → Botón de acción → Atajo → elige ese atajo.")
                    Text("Centro de control (iOS 18): añade el control Atajo y elige ese atajo.")
                    if #available(iOS 18.0, *) {
                        Text("También puedes añadir GimbalKit → Parada. Este control abre la app y la detiene.")
                    }
                    Button {
                        openURL(URL(string: "shortcuts://")!)
                    } label: {
                        Label("Abrir Atajos", systemImage: "arrow.up.forward.app").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(NeuButtonStyle())
                    Text("En la actividad en vivo, PARADA funciona sin abrir la app. El widget de estado abre GimbalKit al tocarlo.")
                        .font(.subheadline).foregroundStyle(palette.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20).frame(maxWidth: 620).frame(maxWidth: .infinity)
        }
        .background(palette.background.ignoresSafeArea())
        .foregroundStyle(palette.text)
        .navigationTitle("Ajustes")
        .navigationBarTitleDisplayMode(.inline)
    }
}
