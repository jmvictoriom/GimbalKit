import CoreBluetooth
import Foundation
import GimbalKitDJI

private final class ConnectionCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.withLock { cancelled = true } }
    var isCancelled: Bool { lock.withLock { cancelled } }
}

public enum BLEError: Error, Equatable {
    case bluetoothUnavailable, notFound, timedOut, discoveryFailed
}

/// Transporte CoreBluetooth para la serie OM: servicio FFF0, notificaciones en FFF4, escritura sin respuesta en FFF5.
/// Primero recupera una Osmo ya conectada al sistema (queda conectada como HID y no se anuncia); si no, escanea por servicio.
/// Todo el estado mutable se toca solo en `queue` (también el delegado).
public final class CoreBluetoothOMTransport: NSObject, OMTransport, @unchecked Sendable {
    public let notifications: AsyncStream<[UInt8]>
    private let callbackLock = NSLock()
    private var disconnectCallback: (@Sendable () -> Void)?
    public var onDisconnect: (@Sendable () -> Void)? {
        get { callbackLock.withLock { disconnectCallback } }
        set { callbackLock.withLock { disconnectCallback = newValue } }
    }
    private var connectionTicket: UUID?

    private let continuation: AsyncStream<[UInt8]>.Continuation
    private let queue = DispatchQueue(label: "gimbalkit.ble")
    private static var service: CBUUID { CBUUID(string: "FFF0") }
    private static var notifyUUID: CBUUID { CBUUID(string: "FFF4") }
    private static var writeUUID: CBUUID { CBUUID(string: "FFF5") }

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var notifyCharacteristic: CBCharacteristic?
    private var writeCharacteristic: CBCharacteristic?
    private var connection: CheckedContinuation<Void, Error>?

    public override init() {
        (notifications, continuation) = AsyncStream.makeStream(of: [UInt8].self)
        super.init()
        central = CBCentralManager(delegate: self, queue: queue)
    }

    public func connect(timeout: TimeInterval = 15) async throws {
        try Task.checkCancellation()
        let ticket = UUID()
        let cancellation = ConnectionCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                queue.async {
                    guard !cancellation.isCancelled else { cont.resume(throwing: CancellationError()); return }
                    guard self.connection == nil else { cont.resume(throwing: BLEError.discoveryFailed); return }
                    self.connectionTicket = ticket
                    self.connection = cont
                    self.queue.asyncAfter(deadline: .now() + timeout) {
                        guard self.connectionTicket == ticket else { return }
                        self.central.stopScan()
                        self.finishConnection(.failure(BLEError.timedOut))
                    }
                    self.beginIfPoweredOn()
                }
            }
        } onCancel: {
            cancellation.cancel()
            self.queue.async {
                guard self.connectionTicket == ticket else { return }
                self.central.stopScan()
                if let peripheral = self.peripheral { self.central.cancelPeripheralConnection(peripheral) }
                self.finishConnection(.failure(CancellationError()))
            }
        }
    }
    public func disconnect() {
        queue.async {
            self.central.stopScan()
            self.finishConnection(.failure(CancellationError()))
            self.notifyCharacteristic = nil; self.writeCharacteristic = nil
            if let peripheral = self.peripheral { self.central.cancelPeripheralConnection(peripheral) }
        }
    }

    public func write(_ bytes: [UInt8]) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                guard let peripheral = self.peripheral, let characteristic = self.writeCharacteristic else {
                    cont.resume(throwing: BLEError.notFound)
                    return
                }
                let size = max(20, peripheral.maximumWriteValueLength(for: .withoutResponse))
                var offset = 0
                while offset < bytes.count {
                    let end = min(offset + size, bytes.count)
                    peripheral.writeValue(Data(bytes[offset..<end]), for: characteristic, type: .withoutResponse)
                    offset = end
                }
                cont.resume()
            }
        }
    }

    // MARK: Conexión (siempre en `queue`)

    private func beginIfPoweredOn() {
        switch central.state {
        case .poweredOn:
            if let found = central.retrieveConnectedPeripherals(withServices: [Self.service]).first {
                attach(found)
            } else {
                central.scanForPeripherals(withServices: [Self.service])
            }
        case .unknown, .resetting:
            break                                   // centralManagerDidUpdateState reintentará
        default:
            finishConnection(.failure(BLEError.bluetoothUnavailable))
        }
    }

    private func attach(_ found: CBPeripheral) {
        central.stopScan()
        peripheral = found
        found.delegate = self
        if found.state == .connected {
            found.discoverServices([Self.service])
        } else {
            central.connect(found)
        }
    }

    private func finishConnection(_ result: Result<Void, Error>) {
        guard let cont = connection else { return }
        connection = nil; connectionTicket = nil
        cont.resume(with: result)
    }
}

extension CoreBluetoothOMTransport: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if connection != nil { beginIfPoweredOn() }
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any], rssi RSSI: NSNumber) {
        attach(peripheral)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([Self.service])
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        finishConnection(.failure(error ?? BLEError.notFound))
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        notifyCharacteristic = nil
        writeCharacteristic = nil
        onDisconnect?()
    }
}

extension CoreBluetoothOMTransport: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == Self.service }) else {
            finishConnection(.failure(BLEError.discoveryFailed))
            return
        }
        peripheral.discoverCharacteristics([Self.notifyUUID, Self.writeUUID], for: service)
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        notifyCharacteristic = service.characteristics?.first { $0.uuid == Self.notifyUUID }
        writeCharacteristic = service.characteristics?.first { $0.uuid == Self.writeUUID }
        guard error == nil, let notify = notifyCharacteristic, writeCharacteristic != nil else {
            finishConnection(.failure(BLEError.discoveryFailed))
            return
        }
        peripheral.setNotifyValue(true, for: notify)
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        finishConnection(error == nil ? .success(()) : .failure(error!))
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, characteristic.uuid == Self.notifyUUID, let data = characteristic.value else { return }
        continuation.yield([UInt8](data))
    }
}
