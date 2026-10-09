//
//  AppleWatchPocWatchApp.swift
//  AppleWatchPocWatch Watch App
//
//  Created by 정홍섭 on 10/8/26.
//

import SwiftUI

@main
struct AppleWatchPocWatch_Watch_AppApp: App {
    @StateObject private var sync = WatchRecordingViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(sync)
        }
    }
}
