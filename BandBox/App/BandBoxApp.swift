//
//  BandBoxApp.swift
//  BandBox
//
//  iOS 15 起可用；最低部署目标 iOS 15.0。
//

import SwiftUI

@main
struct BandBoxApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(model.settings)
        }
    }
}
