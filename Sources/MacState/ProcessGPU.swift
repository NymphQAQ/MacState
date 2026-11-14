import Foundation
import IOKit

struct GPUClientCounter {
    let registryID: UInt64
    let pid: Int32
    let times: [UInt64]?
    var name: String? = nil
}

struct GPUCounterSnapshot {
    let available: Bool
    let clients: [GPUClientCounter]
    var complete = true
    var timestamp: Double? = nil
    var deviceCount = 1

    static func capture() -> GPUCounterSnapshot {
        let began = ProcessInfo.processInfo.systemUptime
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else {
            return GPUCounterSnapshot(available: false, clients: [])
        }
        defer { IOObjectRelease(iterator) }
        var clients: [GPUClientCounter] = [], supported = false, complete = true, seen = Set<UInt64>(), deviceCount = 0
        while case let accelerator = IOIteratorNext(iterator), accelerator != 0 {
            deviceCount += 1
            defer { IOObjectRelease(accelerator) }
            var children: io_iterator_t = 0
            // User clients are registry entries, not published matching services.
            guard IORegistryEntryCreateIterator(accelerator, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &children) == KERN_SUCCESS else { complete = false; continue }
            defer { IOObjectRelease(children) }
            var exposesUsage = false
            while case let service = IOIteratorNext(children), service != 0 {
                defer { IOObjectRelease(service) }
                var properties: Unmanaged<CFMutableDictionary>?, registryID: UInt64 = 0
                guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                      let values = properties?.takeRetainedValue() as? [String: Any],
                      let usage = values["AppUsage"] as? [[String: Any]] else { continue }
                supported = true
                exposesUsage = true
                guard let creator = values["IOUserClientCreator"] as? String,
                      creator.hasPrefix("pid "), let pidText = creator.split(separator: " ").dropFirst().first,
                      let pid = Int32(pidText.trimmingCharacters(in: CharacterSet(charactersIn: ","))),
                      IORegistryEntryGetRegistryEntryID(service, &registryID) == KERN_SUCCESS else { complete = false; continue }
                guard seen.insert(registryID).inserted else { continue }
                let times = usage.compactMap { ($0["accumulatedGPUTime"] as? NSNumber)?.uint64Value }
                if times.count != usage.count { complete = false }
                let name = creator.split(separator: ",", maxSplits: 1).dropFirst().first.map { String($0).trimmingCharacters(in: .whitespaces) }
                clients.append(GPUClientCounter(registryID: registryID, pid: pid, times: times.count == usage.count ? times : nil, name: name))
            }
            if !exposesUsage { complete = false }
        }
        return GPUCounterSnapshot(available: supported, clients: clients, complete: complete,
                                  timestamp: (began + ProcessInfo.processInfo.systemUptime) / 2, deviceCount: deviceCount)
    }
}

struct GPUTimeInterval {
    let percentages: [Int32: Double]
    let nanoseconds: [Int32: Double]
    let complete: Bool
    let start: Double?
    let end: Double?
}

final class ProcessGPUCounters {
    private var previous: GPUCounterSnapshot?
    private var previousIdentities: [Int32: UInt64] = [:]

    // Track each driver client separately. Adding/removing a client must not
    // subtract different lifetime counters or assign past work to a new PID.
    func percentages(_ sample: GPUCounterSnapshot, identities: [Int32: UInt64], elapsed: Double) -> [Int32: Double] {
        interval(sample, identities: identities, elapsed: elapsed).percentages
    }

    func interval(_ sample: GPUCounterSnapshot, identities: [Int32: UInt64], elapsed: Double) -> GPUTimeInterval {
        defer { previous = sample; previousIdentities = identities }
        let duration = sample.timestamp.flatMap { now in previous?.timestamp.map { now - $0 } } ?? elapsed
        guard sample.available, sample.complete, sample.deviceCount == 1,
              let previous, previous.available, previous.complete, previous.deviceCount == 1,
              duration.isFinite, duration > 0, duration <= 30 else {
            return GPUTimeInterval(percentages: [:], nanoseconds: [:], complete: false, start: nil, end: nil)
        }
        let oldClients = Dictionary(uniqueKeysWithValues: previous.clients.map { ($0.registryID, $0) })
        let currentIDs = Set(sample.clients.map(\.registryID))
        var invalid = Set(previous.clients.filter { !currentIDs.contains($0.registryID) }.map(\.pid))
        var deltas: [Int32: Double] = [:]
        for client in sample.clients {
            guard let old = oldClients[client.registryID], old.pid == client.pid,
                  identities[client.pid] == nil || previousIdentities[client.pid] == nil || identities[client.pid] == previousIdentities[client.pid],
                  let before = old.times, let after = client.times, before.count == after.count,
                  zip(after, before).allSatisfy({ $0 >= $1 }) else { invalid.insert(client.pid); continue }
            let delta = zip(after, before).reduce(0.0) { $0 + Double($1.0 - $1.1) }
            deltas[client.pid, default: 0] += delta
        }
        var result: [Int32: Double] = [:]
        for (pid, identity) in identities where previousIdentities[pid] == identity && !invalid.contains(pid) {
            // No GPU client on either sample means no observed GPU work. It is
            // only zero when this driver exposes the counters, never on fallback.
            result[pid] = (deltas[pid] ?? 0) / duration / 1e9 * 100
        }
        // Keep clients outside the process list in the denominator. Protected
        // processes and processes that exited must not donate their work to apps.
        return GPUTimeInterval(percentages: result, nanoseconds: deltas.filter { !invalid.contains($0.key) },
                               complete: invalid.isEmpty, start: previous.timestamp, end: sample.timestamp)
    }
}
