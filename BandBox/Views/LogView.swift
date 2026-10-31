//
//  LogView.swift
//  BandBox
//
//  协议级日志，排障时的主要依据
//

import SwiftUI
import UIKit

struct LogView: View {
    let logs: [String]
    @Environment(\.presentationMode) private var presentationMode
    @State private var filter = ""

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                    TextField("过滤日志", text: $filter)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }
                .padding(10)
                .background(Color(.systemGray6))

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(filtered.indices, id: \.self) { index in
                            Text(filtered[index])
                                .font(.system(.caption, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 1)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
            .navigationTitle("协议日志")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { presentationMode.wrappedValue.dismiss() }
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { UIPasteboard.general.string = filtered.joined(separator: "\n") } label: {
                        Image(systemName: "doc.on.doc")
                    }
                }
            }
        }
    }

    private var filtered: [String] {
        guard !filter.isEmpty else { return logs }
        return logs.filter { $0.localizedCaseInsensitiveContains(filter) }
    }
}
