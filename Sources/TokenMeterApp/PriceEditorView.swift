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
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                    Text("编辑单价")
                        .font(.caption)
                    Text("(\(rows.count) 个模型)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
            Text("单位：美元 / 百万 tokens；名称按子串匹配，从上到下先命中先生效。")
                .font(.caption2).foregroundStyle(.tertiary)
            columnHeader
            ScrollView {
                VStack(spacing: 4) {
                    ForEach($rows) { $r in
                        HStack(spacing: 4) {
                            TextField("模型名称", text: $r.pattern)
                                .textFieldStyle(.plain)
                                .padding(.horizontal, 5).padding(.vertical, 3)
                                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.06)))
                                .frame(width: 132)
                            priceField($r.input)
                            priceField($r.output)
                            priceField($r.cr)
                            priceField($r.cw)
                            Button {
                                rows.removeAll { $0.id == r.id }
                            } label: {
                                Image(systemName: "minus.circle")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.borderless)
                            .help("删除这一行")
                        }
                        .font(.caption2)
                    }
                }
            }
            .frame(height: 168)
            .scrollIndicators(.hidden)
            .padding(.trailing, 4)
            HStack(spacing: 8) {
                Button("保存") { save() }
                Button("加一行") { rows.append(Row(pattern: "", input: "", output: "", cr: "", cw: "")) }
                Button("恢复内置") { reset() }
                Spacer()
                Text(message).font(.caption2).foregroundStyle(.secondary)
            }
            .font(.caption)
            }
        }
        .onAppear(perform: reload)
    }

    /// 列头：与下方输入框同宽对齐
    private func priceField(_ text: Binding<String>) -> some View {
        TextField("0", text: text)
            .textFieldStyle(.plain)
            .monospacedDigit()
            .padding(.horizontal, 5).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.06)))
            .frame(width: 46)
    }

    private var columnHeader: some View {
        HStack(spacing: 4) {
            Text("模型名称").frame(width: 132, alignment: .leading)
            Text("输入").frame(width: 46)
            Text("输出").frame(width: 46)
            Text("缓存读").frame(width: 46)
            Text("缓存写").frame(width: 46)
            Spacer(minLength: 0)
        }
        .font(.system(size: 9))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 2)
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
