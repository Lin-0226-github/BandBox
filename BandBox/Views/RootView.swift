//
//  RootView.swift
//  BandBox
//

import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            DeviceView()
                .tabItem { Label("设备", systemImage: "circle.hexagongrid") }
            GuideView()
                .tabItem { Label("指引", systemImage: "book") }
            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
        }
        .accentColor(.orange)
    }
}
