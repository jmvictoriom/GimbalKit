// Genera el icono de GimbalKit (1024×1024, sin transparencia) con CoreGraphics.
// Uso: swift scripts/make-icon.swift <salida.png>
// Diseño: un anillo abierto con degradado (el giro del estabilizador), un punto luminoso en la abertura y una lente cálida en el centro.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("Uso: swift scripts/make-icon.swift <salida.png>\n".utf8))
    exit(1)
}
let size = 1024
let space = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                          space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { exit(2) }

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [CGFloat((hex >> 16) & 255) / 255, CGFloat((hex >> 8) & 255) / 255,
                                            CGFloat(hex & 255) / 255, alpha])!
}
let s = CGFloat(size)
let c = CGPoint(x: 512, y: 512)

// Fondo: degradado diagonal violeta → índigo → azul cielo, con luz arriba a la izquierda y viñeta abajo a la derecha.
let background = CGGradient(colorsSpace: space, colors: [rgb(0x7C3AED), rgb(0x4F46E5), rgb(0x0EA5E9)] as CFArray,
                            locations: [0, 0.5, 1])!
ctx.drawLinearGradient(background, start: CGPoint(x: 0, y: s), end: CGPoint(x: s, y: 0), options: [])
let light = CGGradient(colorsSpace: space, colors: [rgb(0xFFFFFF, 0.30), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(light, startCenter: CGPoint(x: 220, y: 860), startRadius: 0,
                       endCenter: CGPoint(x: 220, y: 860), endRadius: 820, options: [])
let vignette = CGGradient(colorsSpace: space, colors: [rgb(0x000000, 0.28), rgb(0x000000, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(vignette, startCenter: CGPoint(x: 900, y: 120), startRadius: 0,
                       endCenter: CGPoint(x: 900, y: 120), endRadius: 760, options: [])

// Anillo abierto (hueco a la derecha), con sombra y degradado vertical.
let radius: CGFloat = 275, width: CGFloat = 124
ctx.setLineCap(.round)
ctx.setLineWidth(width)
ctx.addArc(center: c, radius: radius, startAngle: 42 * .pi / 180, endAngle: 318 * .pi / 180, clockwise: false)
ctx.replacePathWithStrokedPath()
let ringPath = ctx.path!
ctx.beginPath()

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -26), blur: 46, color: rgb(0x1E1B4B, 0.55))
ctx.setFillColor(rgb(0xFFFFFF))
ctx.addPath(ringPath)
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(ringPath)
ctx.clip()
let ringGradient = CGGradient(colorsSpace: space, colors: [rgb(0xFFFFFF), rgb(0xC7D2FE)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(ringGradient, start: CGPoint(x: 512, y: 850), end: CGPoint(x: 512, y: 175),
                        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
ctx.restoreGState()

// Punto luminoso en la abertura: el eje que gira.
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 56, color: rgb(0xFFFFFF, 0.95))
ctx.setFillColor(rgb(0xFFFFFF))
ctx.fillEllipse(in: CGRect(x: 805 - 54, y: 512 - 54, width: 108, height: 108))
ctx.restoreGState()

// Lente central: disco con degradado cálido y sombra suave.
let lens: CGFloat = 132
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -22), blur: 40, color: rgb(0x3B0764, 0.5))
ctx.setFillColor(rgb(0xFF7A59))
ctx.fillEllipse(in: CGRect(x: c.x - lens, y: c.y - lens, width: lens * 2, height: lens * 2))
ctx.restoreGState()

ctx.saveGState()
ctx.addEllipse(in: CGRect(x: c.x - lens, y: c.y - lens, width: lens * 2, height: lens * 2))
ctx.clip()
let warm = CGGradient(colorsSpace: space, colors: [rgb(0xFFE9A8), rgb(0xFF9A4D), rgb(0xFF3D81)] as CFArray,
                      locations: [0, 0.5, 1])!
ctx.drawRadialGradient(warm, startCenter: CGPoint(x: c.x - 44, y: c.y + 56), startRadius: 0,
                       endCenter: CGPoint(x: c.x, y: c.y), endRadius: lens * 1.25, options: [.drawsAfterEndLocation])
ctx.restoreGState()

// Destello de la lente.
ctx.setFillColor(rgb(0xFFFFFF, 0.55))
ctx.fillEllipse(in: CGRect(x: c.x - 74, y: c.y + 30, width: 54, height: 34))

guard let image = ctx.makeImage(),
      let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL,
                                                        UTType.png.identifier as CFString, 1, nil) else { exit(3) }
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else { exit(4) }
print("Icono escrito en \(CommandLine.arguments[1])")
