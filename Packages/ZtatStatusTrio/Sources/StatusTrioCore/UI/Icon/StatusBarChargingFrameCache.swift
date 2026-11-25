import CoreGraphics

/// Lazily renders steady menu-bar charging frames on demand per phase step and
/// caches each resulting bitmap for subsequent ticks.
///
/// ZTAT-PATCH: Perf 2 — switched from synchronous 36-frame eager generation on
/// MainActor to a lazy per-step `[CGImage?]` cache, eliminating main-thread
/// spikes whenever battery percentage or icon state changes during charging.
@MainActor
final class StatusBarChargingFrameCache {
    struct VariantKey: Equatable {
        let renderKey: StatusBarRenderKey
        let backingScale: CGFloat
        let heartbeatMultiplier: Double
    }

    private struct Variant {
        let key: VariantKey
        var frames: [CGImage?]
        var populatedCount: Int
    }

    static let steadyFrameCount = Int(
        (ChargingEffectTimeline.steadyCycleDuration
            * Double(ChargingEffectTimeline.framesPerSecond)).rounded()
    )
    static let maximumVariants = 2

    /// Most recently used first.
    private var variants: [Variant] = []
    /// A variant key whose rasterization failed is not retried on every 20-Hz tick.
    /// `reset()` (a new static key) clears this so the next state retries.
    private var failedKey: VariantKey?

    /// Cumulative work counters: a cached steady tick must not move them.
    private(set) var rebuildCount = 0
    private(set) var rasterizedFrameCount = 0

    func needsFrames(
        for phase: ChargingEffectPhase,
        key renderKey: StatusBarRenderKey,
        backingScale: CGFloat
    ) -> Bool {
        guard isSupported(phase, backingScale: backingScale) else { return false }
        let nextKey = variantKey(for: phase, key: renderKey, backingScale: backingScale)
        guard failedKey != nextKey else { return false }
        guard let existingIndex = index(of: nextKey) else { return true }
        return variants[existingIndex].frames[phase.step] == nil
    }

    func image(
        for phase: ChargingEffectPhase,
        key renderKey: StatusBarRenderKey,
        backingScale: CGFloat,
        renderFrame: (ChargingEffectPhase) -> CGImage?
    ) -> CGImage? {
        guard isSupported(phase, backingScale: backingScale) else { return nil }

        let nextKey = variantKey(for: phase, key: renderKey, backingScale: backingScale)
        guard failedKey != nextKey else { return nil }

        if let existingIndex = index(of: nextKey) {
            var variant = variants.remove(at: existingIndex)
            if let cached = variant.frames[phase.step] {
                variants.insert(variant, at: 0)
                return cached
            }
            let framePhase = ChargingEffectPhase(
                step: phase.step,
                stepsPerCycle: Self.steadyFrameCount,
                kind: .steady,
                heartbeatMultiplier: phase.heartbeatMultiplier
            )
            guard let frame = renderFrame(framePhase) else {
                variants.insert(variant, at: 0)
                failedKey = nextKey
                return nil
            }
            variant.frames[phase.step] = frame
            variant.populatedCount += 1
            variants.insert(variant, at: 0)
            rasterizedFrameCount += 1
            return frame
        }

        // Lazy variant creation: render only the current phase step on demand.
        let framePhase = ChargingEffectPhase(
            step: phase.step,
            stepsPerCycle: Self.steadyFrameCount,
            kind: .steady,
            heartbeatMultiplier: phase.heartbeatMultiplier
        )
        guard let frame = renderFrame(framePhase) else {
            failedKey = nextKey
            return nil
        }

        var frames = Array<CGImage?>(repeating: nil, count: Self.steadyFrameCount)
        frames[phase.step] = frame
        variants.insert(Variant(key: nextKey, frames: frames, populatedCount: 1), at: 0)
        if variants.count > Self.maximumVariants {
            variants.removeLast(variants.count - Self.maximumVariants)
        }
        rebuildCount += 1
        rasterizedFrameCount += 1
        return frame
    }

    /// Number of populated frames in the most recently used set.
    var frameCount: Int { variants.first?.populatedCount ?? 0 }

    /// How many frame sets are resident, bounded by `maximumVariants`.
    var variantCount: Int { variants.count }

    func reset() {
        variants.removeAll(keepingCapacity: false)
        failedKey = nil
    }

    func trimForMemoryPressure() {
        if variants.count > 1 { variants.removeLast(variants.count - 1) }
    }

    private func variantKey(
        for phase: ChargingEffectPhase,
        key renderKey: StatusBarRenderKey,
        backingScale: CGFloat
    ) -> VariantKey {
        VariantKey(
            renderKey: StatusBarRenderKey(
                scene: renderKey.scene,
                iconSize: renderKey.iconSize,
                backingScale: renderKey.backingScale,
                appearanceName: renderKey.appearanceName,
                phase: nil
            ),
            backingScale: backingScale,
            heartbeatMultiplier: phase.heartbeatMultiplier
        )
    }

    private func index(of key: VariantKey) -> Int? {
        variants.firstIndex { $0.key == key && $0.frames.count == Self.steadyFrameCount }
    }

    private func isSupported(_ phase: ChargingEffectPhase, backingScale: CGFloat) -> Bool {
        phase.kind == .steady
            && phase.stepsPerCycle == Self.steadyFrameCount
            && (0..<Self.steadyFrameCount).contains(phase.step)
            && phase.heartbeatMultiplier.isFinite
            && phase.heartbeatMultiplier >= 0
            && backingScale.isFinite
            && backingScale > 0
    }
}
