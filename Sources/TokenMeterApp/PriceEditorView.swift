#if os(macOS)
import SwiftUI
import TokenMeterCore

/// 面板内价格表编辑器：直接改 pricing.json，免手编辑 JSON
struct PriceEditorView: View {
    @EnvironmentObject var model: AppModel

    struct Row: Identifiable {
        let id = UUID()
        var pattern: String
        var input: String
        var output: String
        var cr: String
        var cw: String
    }

    @State private var rows: [Row] = []
    @State private var message = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("价格表（USD / 1M tokens，子串匹配、先命中先生效）")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 4) {
                    ForEach($rows) { $r in
                        HStack(spacing: 4) {
                            TextField("pattern", text: $r.pattern)
                                .textFieldStyle(.roundedBorder).frame(width: 120)
                            TextField("输入", text: $r.input)
                                .textFieldStyle(.roundedBorder).frame(width: 46)
                            TextField("输出", text: $r.output)
                                .textFieldStyle(.roundedBorder).frame(width: 46)
                            TextField("缓存读", text: $r.cr)
                                .textFieldStyle(.roundedBorder).frame(width: 46)
                            TextField("缓存写", text: $r.cw)
                                .textFieldStyle(.roundedBorder).frame(width: 46)
                            Button {
                                rows.removeAll { $0.id == r.id }
                            } label: {
                                Image(systemName: "minus.circle").font(.caption)
                            }
                            .buttonStyle(.borderless)
                        }
                        .font(.caption2)
                    }
                }
            }
            .frame(height: 180)
            .scrollIndicators(.hidden)
            .padding(.trailing, 6)
            HStack(spacing: 8) {
                Button("保存") { save() }
                Button("加一行") { rows.append(Row(pattern: "", input: "", output: "", cr: "", cw: "")) }
                Button("恢复内置") { reset() }
                Spacer()
                Text(message).font(.caption2).foregroundStyle(.secondary)
            }
            .font(.caption)
        }
        .onAppear(perform: reload)
    }

    private func reload() {
        rows = PricingTable.load().prices.map {
            Row(pattern: $0.pattern,
                input: String($0.input),
                output: String($0.output),
                cr: $0.cacheRead.map { String($0) } ?? "",
                cw: $0.cacheWrite.map { String($0) } ?? "")
        }
        message = ""
    }

    private func save() {
        var prices: [ModelPrice] = []
        for r in rows {
            guard !r.pattern.isEmpty,
                  let i = Double(r.input), let o = Double(r.output) else { continue }
            prices.append(ModelPrice(pattern: r.pattern, input: i, output: o,
                                     cacheRead: Double(r.cr), cacheWrite: Double(r.cw)))
        }
        guard !prices.isEmpty else { message = "没有有效行"; return }
        do {
            try PricingTable.save(PricingTable(prices: prices))
            message = "已保存 \(prices.count) 条"
            model.refresh()
        } catch {
            message = "保存失败：\(error.localizedDescription)"
        }
    }

    private func reset() {
        try? FileManager.default.removeItem(at: PricingTable.overrideURL)
        reload()
        model.refresh()
        message = "已恢复内置价格表"
    }
}
#endif
