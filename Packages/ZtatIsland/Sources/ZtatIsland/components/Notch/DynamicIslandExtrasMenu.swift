// SPDX-License-Identifier: GPL-3.0-or-later
// ZTAT-PATCH: Rebranded extras menu routing Settings to ztat's unified Settings window (removed GitHub/Donate/Quit).

import SwiftUI
import ZtatCore

struct DynamicIslandLargeButtons: View {
    var action: () -> Void
    var icon: Image
    var title: String
    var body: some View {
        Button(
            action: action,
            label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 12.0).fill(.black).frame(width: 70, height: 70)
                    VStack(spacing: 8) {
                        icon.resizable()
                            .aspectRatio(contentMode: .fit).frame(width: 20)
                        Text(title).font(.body)
                    }
                }
            }).buttonStyle(PlainButtonStyle()).shadow(color: .black.opacity(0.5), radius: 10)
    }
}

struct DynamicIslandExtrasMenu: View {
    @ObservedObject var vm: DynamicIslandViewModel

    var body: some View {
        VStack {
            HStack(spacing: 20) {
                hide
                settings
            }
        }
    }

    var settings: some View {
        Button(action: {
            ZtatHostBridge.shared.openSettings(route: .island(sectionID: "general"))
        }) {
            ZStack {
                RoundedRectangle(cornerRadius: 12.0).fill(.black).frame(width: 70, height: 70)
                VStack(spacing: 8) {
                    Image(systemName: "gear").resizable()
                        .aspectRatio(contentMode: .fit).frame(width: 20)
                    Text("Settings").font(.body)
                }
            }
        }
        .buttonStyle(PlainButtonStyle()).shadow(color: .black.opacity(0.5), radius: 10)
    }

    var hide: some View {
        DynamicIslandLargeButtons(
            action: {
                vm.close()
            },
            icon: Image(systemName: "arrow.down.forward.and.arrow.up.backward"),
            title: "Hide"
        )
    }
}
