//
//  AppleWatchPoCApp.swift
//  AppleWatchPoC
//
//  Created by 정홍섭 on 10/7/26.
//

import SwiftUI

@main
struct AppleWatchPoCApp: App {
    @StateObject private var sync = PhoneRecordingViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(sync)
        }
    }
}
