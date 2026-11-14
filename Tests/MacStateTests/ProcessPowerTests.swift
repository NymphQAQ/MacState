import Foundation
import Testing
import Metal
import SystemBridge
@testable import MacState

private func process(_ pid: Int32, parent: Int32 = 1, path: String = "", cpu: Double? = 0, gpu: Double? = 0, power: Double? = nil, responsible: Int32? = nil) -> ProcessRow {
    ProcessRow(pid: pid, parent: parent, name: "p\(pid)", path: path, user: "test", threads: 1, cpu: cpu, memory: 0, resident: 0,
               readRate: 0, writeRate: 0, wakeups: 0, power: power, gpu: gpu, responsible: responsible, startAbstimeNS: UInt64(pid) * 100, status: "test")
}

@Test func gpuTracksClientsRatherThanSubtractingDifferentLifetimeTotals() {
    let tracker = ProcessGPUCounters()
    func sample(_ clients: [GPUClientCounter]) -> GPUCounterSnapshot { GPUCounterSnapshot(available: true, clients: clients) }
    let identities: [Int32: UInt64] = [1: 10, 2: 20, 3: 30]
    let a = GPUClientCounter(registryID: 10, pid: 1, times: [10_000_000_000, 2_000_000_000])
    #expect(tracker.percentages(sample([a]), identities: identities, elapsed: 1).isEmpty)
    let b = GPUClientCounter(registryID: 10, pid: 1, times: [11_000_000_000, 2_500_000_000])
    let result = tracker.percentages(sample([b]), identities: identities, elapsed: 2)
    #expect(result[1] == 75)
    #expect(result[2] == 0)
    let newClient = GPUClientCounter(registryID: 11, pid: 1, times: [90_000_000_000])
    #expect(tracker.percentages(sample([b, newClient]), identities: identities, elapsed: 1)[1] == nil)
    #expect(tracker.percentages(sample([b]), identities: identities, elapsed: 1)[1] == nil) // removal
    #expect(tracker.percentages(sample([a]), identities: identities, elapsed: 1)[1] == nil) // reset
    #expect(tracker.percentages(sample([a]), identities: [1: 99, 2: 20], elapsed: 1)[1] == nil) // reused PID
    #expect(tracker.percentages(GPUCounterSnapshot(available: false, clients: []), identities: identities, elapsed: 1).isEmpty)
    #expect(tracker.percentages(sample([a]), identities: identities, elapsed: 1).isEmpty) // lost baseline
    #expect(tracker.percentages(sample([a]), identities: identities, elapsed: 60).isEmpty) // sleep gap
}

@Test func powerProcessSummaryIncludesOnlyAvailableEnergyWithoutDeviceAllocation() {
    var rows = [process(1, cpu: nil, gpu: nil), process(2), process(3)]
    rows[0].cpuPower = 999; rows[0].gpuPower = 999
    let readings = [Int32(1): ProcessEnergyReading(power: 2, smoothedPower: 3, lifetimeEnergy: 10),
                    Int32(2): ProcessEnergyReading(power: 0, smoothedPower: 0, lifetimeEnergy: 0)]
    let summary = ProcessEnergyLedger.apply(readings, to: &rows)
    #expect(rows[0].power == 2 && rows[1].power == 0 && rows[0].smoothedPower == 3)
    #expect(rows[0].lifetimeEnergy == 10 && rows[0].energyImpact == nil)
    #expect(rows[2].power == nil && rows[0].cpuPower == nil && rows[0].gpuPower == nil)
    #expect(summary.measuredPower == 2 && summary.measuredProcesses == 2 && summary.totalProcesses == 3)
    #expect(ProcessEnergyLedger.apply([:], to: &rows).measuredPower == nil)
    #expect(rows.allSatisfy { $0.power == nil && $0.smoothedPower == nil && $0.lifetimeEnergy == nil })
}

@Test func applicationGroupingIncludesDetachedHelpersAndDoesNotGuessSharedServices() {
    let roots = [UsageAppRoot(pid: 100, bundlePath: "/Apps/Foo.app", application: UsageApplication(id: "foo", name: "Foo")),
                 UsageAppRoot(pid: 200, bundlePath: "/Apps/Bar.app", application: UsageApplication(id: "bar", name: "Bar"))]
    let rows = [process(100, power: 1),
                process(101, path: "/Apps/Foo.app/Contents/Helpers/GPU", power: 2.5),
                process(102, parent: 101, path: "/usr/bin/tool", power: 0.5),
                process(104, parent: 1, path: "/System/com.apple.WebKit.GPU", power: 1.25, responsible: 100),
                process(103, path: "/Apps/Foo.app-copy/Contents/tool", power: 1),
                process(200, power: nil), process(201, parent: 200, power: 1),
                process(300, path: "/System/WindowServer", power: 1),
                process(301, parent: 302, power: nil), process(302, parent: 301)]
    let groups = ApplicationPowerGrouping.group(rows, roots: roots)
    let foo = groups.first { $0.application.id == "foo" }!
    #expect(foo.processCount == 4 && foo.power == 5.25)
    let bar = groups.first { $0.application.id == "bar" }!
    #expect(bar.processCount == 2 && bar.measuredProcessCount == 1 && bar.power == nil)
    #expect(groups.count == 3)
    #expect(groups.first { $0.application.id == "macstate:other-processes" }?.power == 2)
    #expect(groups.first { $0.application.id == "macstate:system" } == nil)
}

@Test func gpuFrequencyUsesActiveResidencyAndRejectsUnmappedStates() {
    let states = [GPUResidency(name: "OFF", time: 80), GPUResidency(name: "P1", time: 10), GPUResidency(name: "P2", time: 10)]
    let result = GPUFrequencyMath.average(states: states, frequencies: [400, 800])
    #expect(result.frequency == 600 && result.active == 20)
    #expect(GPUFrequencyMath.average(states: states + [GPUResidency(name: "P3", time: 0)], frequencies: [400, 800]).frequency == 600)
    #expect(GPUFrequencyMath.average(states: states + [GPUResidency(name: "P3", time: 1)], frequencies: [400, 800]).frequency == nil)
    #expect(GPUFrequencyMath.average(states: states, frequencies: [400]).frequency == nil)
    #expect(GPUFrequencyMath.average(states: [GPUResidency(name: "OFF", time: 100), GPUResidency(name: "P1", time: 0)], frequencies: [400]).frequency == nil)
    #expect(GPUFrequencyMath.average(states: [GPUResidency(name: "mystery", time: 10)], frequencies: [400]).frequency == nil)
}

@Test func gpuCountersObserveOwnMetalWorkInsteadOfForegroundOwnership() throws {
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return }
    // A short compute command is enough to verify the driver counter's units
    // and ownership, without running a sustained stress test.
    let source = """
    #include <metal_stdlib>
    using namespace metal;
    kernel void probe(device float *output [[buffer(0)]], uint i [[thread_position_in_grid]]) {
        float x = float(i + 1);
        for (uint j = 0; j < 2048; j++) x = sqrt(x + 1.01f);
        output[i] = x;
    }
    """
    let library = try device.makeLibrary(source: source, options: nil)
    let function = try #require(library.makeFunction(name: "probe"))
    let pipeline = try device.makeComputePipelineState(function: function)
    let buffer = try #require(device.makeBuffer(length: 65_536 * MemoryLayout<Float>.size, options: .storageModeShared))
    func work() throws {
        let command = try #require(queue.makeCommandBuffer()), encoder = try #require(command.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline); encoder.setBuffer(buffer, offset: 0, index: 0)
        encoder.dispatchThreads(MTLSize(width: 65_536, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: pipeline.threadExecutionWidth, height: 1, depth: 1))
        encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
        #expect(command.status == .completed)
    }
    try work() // create the driver client before establishing the baseline
    let first = GPUCounterSnapshot.capture()
    guard first.available else { return } // unsupported drivers are covered by deterministic tests
    let pid = Int32(ProcessInfo.processInfo.processIdentifier)
    let tracker = ProcessGPUCounters(), identity: [Int32: UInt64] = [pid: 1]
    _ = tracker.percentages(first, identities: identity, elapsed: 1)
    #expect(first.clients.contains { $0.pid == pid })
    // Driver publication can lag command completion. Other optical tests also
    // create/dispose clients in this process; wait for a stable interval rather
    // than treating a missing interval as a valid zero measurement.
    let deadline = ProcessInfo.processInfo.systemUptime + 2
    var before = ProcessInfo.processInfo.systemUptime
    var observed = false
    repeat {
        try work()
        Thread.sleep(forTimeInterval: 0.05)
        let now = ProcessInfo.processInfo.systemUptime
        let rate = tracker.percentages(GPUCounterSnapshot.capture(), identities: identity, elapsed: now-before)
        before = now
        observed = (rate[pid] ?? 0) > 0
    } while !observed && before < deadline
    #expect(observed, "The driver must publish a positive own-process GPU interval within two seconds")
}
