//
//  CRSMemoriesWatchApp.swift  (Apple Watch side)
//
//  The companion to CRS Memories on iPhone. The watch doesn't make montages
//  itself — it shows what the iPhone is working on, starts an export from
//  your wrist, and keeps your recent montages to replay.
//

import SwiftUI

@main
struct WatchApp: App {
    init() {
        PhoneLink.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            WatchRootView()
        }
    }
}
