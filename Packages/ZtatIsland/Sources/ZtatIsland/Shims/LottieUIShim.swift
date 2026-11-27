// SPDX-License-Identifier: GPL-3.0-or-later
// ZTAT-PATCH: Lightweight native SwiftUI wrapper over source-compiled Lottie (replaces LottieUI + binary lottie-spm).

import AppKit
import Foundation
import Lottie
import SwiftUI

enum LULoadType: Equatable {
    case loadedFrom(URL)
    case filepath(String)
    case name(String, Bundle = ZtatIslandResources.bundle)
}

struct LUStateData: Equatable {
    var type: LULoadType
    var speed: Double
    var loopMode: LottieLoopMode

    init(type: LULoadType, speed: Double = 1.0, loopMode: LottieLoopMode = .loop) {
        self.type = type
        self.speed = speed
        self.loopMode = loopMode
    }
}

struct LottieView: NSViewRepresentable {
    let state: LUStateData

    init(state: LUStateData) {
        self.state = state
    }

    final class Coordinator {
        var loadedKey: String = ""
        let animationView = Lottie.LottieAnimationView()

        init() {
            animationView.contentMode = .scaleAspectFit
            animationView.backgroundBehavior = .pauseAndRestore
            animationView.translatesAutoresizingMaskIntoConstraints = false
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        let animView = context.coordinator.animationView
        container.addSubview(animView)
        NSLayoutConstraint.activate([
            animView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            animView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            animView.topAnchor.constraint(equalTo: container.topAnchor),
            animView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        loadIfNeeded(coordinator: context.coordinator)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        loadIfNeeded(coordinator: context.coordinator)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.animationView.stop()
        coordinator.animationView.animation = nil
        coordinator.loadedKey = ""
    }

    private func loadIfNeeded(coordinator: Coordinator) {
        let animView = coordinator.animationView
        animView.animationSpeed = CGFloat(max(0.05, state.speed))
        animView.loopMode = state.loopMode

        let key = "\(state.type)"
        guard coordinator.loadedKey != key else {
            if !animView.isAnimationPlaying, animView.animation != nil {
                animView.play()
            }
            return
        }
        coordinator.loadedKey = key

        switch state.type {
        case .loadedFrom(let rawURL):
            let url = ZtatIslandResources.resolveLottieURL(rawURL)
            if url.isFileURL {
                if let animation = LottieAnimation.filepath(url.path) {
                    animView.animation = animation
                    animView.play()
                }
            } else {
                LottieAnimation.loadedFrom(url: url, closure: { animation in
                    DispatchQueue.main.async {
                        guard coordinator.loadedKey == key, let animation else { return }
                        animView.animation = animation
                        animView.play()
                    }
                }, animationCache: DefaultAnimationCache.sharedCache)
            }
        case .filepath(let path):
            let resolved = ZtatIslandResources.resolveLottieURL(URL(fileURLWithPath: path))
            if let animation = LottieAnimation.filepath(resolved.path) {
                animView.animation = animation
                animView.play()
            }
        case .name(let name, let bundle):
            if let animation = LottieAnimation.named(name, bundle: bundle) {
                animView.animation = animation
                animView.play()
            }
        }
    }
}
