// SPDX-License-Identifier: GPL-3.0-or-later
// ZTAT-PATCH: Vendored pure-Swift SkyLight lock-screen space delegator (replaces external SkyLightWindow package).

import AppKit
import Darwin
import Foundation

final class SkyLightOperator {
    static let shared = SkyLightOperator()

    private typealias SLSMainConnectionIDFunc = @convention(c) () -> Int32
    private typealias SLSSpaceCreateFunc = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias SLSSpaceSetAbsoluteLevelFunc = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias SLSShowSpacesFunc = @convention(c) (Int32, CFArray) -> Int32
    private typealias SLSSpaceAddWindowsAndRemoveFromSpacesFunc = @convention(c) (Int32, Int32, CFArray, Int32) -> Int32

    private let connection: Int32
    private let space: Int32
    private let addWindowsFunc: SLSSpaceAddWindowsAndRemoveFromSpacesFunc?

    private init() {
        let path = "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight"
        guard let handle = dlopen(path, RTLD_LAZY) else {
            self.connection = 0
            self.space = 0
            self.addWindowsFunc = nil
            return
        }

        let mainConn = dlsym(handle, "SLSMainConnectionID").map { unsafeBitCast($0, to: SLSMainConnectionIDFunc.self) }
        let createSpace = dlsym(handle, "SLSSpaceCreate").map { unsafeBitCast($0, to: SLSSpaceCreateFunc.self) }
        let setLevel = dlsym(handle, "SLSSpaceSetAbsoluteLevel").map { unsafeBitCast($0, to: SLSSpaceSetAbsoluteLevelFunc.self) }
        let showSpaces = dlsym(handle, "SLSShowSpaces").map { unsafeBitCast($0, to: SLSShowSpacesFunc.self) }
        let addWindows = dlsym(handle, "SLSSpaceAddWindowsAndRemoveFromSpaces").map {
            unsafeBitCast($0, to: SLSSpaceAddWindowsAndRemoveFromSpacesFunc.self)
        }

        guard let mainConn, let createSpace, let setLevel, let showSpaces, let addWindows else {
            self.connection = 0
            self.space = 0
            self.addWindowsFunc = nil
            return
        }

        let cid = mainConn()
        let sid = createSpace(cid, 1, 0)
        _ = setLevel(cid, sid, 400)
        let spaceList = [NSNumber(value: sid)] as CFArray
        _ = showSpaces(cid, spaceList)

        self.connection = cid
        self.space = sid
        self.addWindowsFunc = addWindows
    }

    func delegateWindow(_ window: NSWindow) {
        guard connection != 0, space != 0, let addWindowsFunc else { return }
        let windowID = window.windowNumber
        guard windowID > 0 else { return }
        let list = [NSNumber(value: windowID)] as CFArray
        _ = addWindowsFunc(connection, space, list, 7)
    }
}
