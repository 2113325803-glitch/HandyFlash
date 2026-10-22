import SwiftUI
import UIKit

/// 卡片页：按日期分组的卡片库。
///
/// 交互：
/// - 顶部随机显示一句激励语，每次进入页面换一句；
/// - 列表一行代表一天（“10月21日”），点进去是当天的沉浸式翻卡；
/// - 左滑一行可以删除这一天的全部卡片（会先弹确认）。
///
/// 这里不再提供“一次删光所有卡片”的入口：删除只能按天或按张进行。
struct CardsView: View {
    @ObservedObject var store: FlashcardStore

    /// 本次进入页面显示的激励语。
    @State private var motivation = MotivationPhrases.random()

    /// 待确认删除的日期分组；非 `nil` 时弹确认框。
    @State private var pendingDeletion: CardDayGroup?

    var body: some View {
        VStack(spacing: 0) {
            motivationBar

            if store.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("卡片")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // 每次回到这一页都换一句：切标签回来、从集合里返回都算。
            motivation = MotivationPhrases.random()
        }
        .confirmationDialog(
            deletionTitle,
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { isPresented in
                    if !isPresented { pendingDeletion = nil }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("删除这天的 \(pendingDeletion.map(\.count) ?? 0) 张卡片", role: .destructive) {
                if let group = pendingDeletion {
                    // 按天删除：只删这一天的 ID，其它日期不受影响。
                    store.remove(ids: group.cards.map(\.id))
                }
                pendingDeletion = nil
            }
            Button("取消", role: .cancel) {
                pendingDeletion = nil
            }
        } message: {
            Text("删除后无法恢复，其它日期的卡片不受影响。")
        }
    }

    // MARK: - 随机激励语

    private var motivationBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(Color.accentColor)

            Text(motivation)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("今日激励：\(motivation)")
    }

    // MARK: - 集合列表

    private var list: some View {
        List {
            ForEach(store.dayGroups) { group in
                NavigationLink {
                    DayCollectionView(day: group.day, store: store)
                } label: {
                    CardDayRow(group: group)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        pendingDeletion = group
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private var deletionTitle: String {
        guard let group = pendingDeletion else { return "删除卡片？" }
        return "删除 \(CardDayFormatter.title(for: group.day)) 的卡片？"
    }

    // MARK: - 空状态

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.stack.3d.up.slash")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)

            Text("还没有卡片")
                .font(.headline)

            Text("去「采集」页写一张，停笔几秒后会自动收进来。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: 320)
        .accessibilityElement(children: .combine)
    }
}

/// 集合列表的一行：封面 + 日期 + 当天张数。
struct CardDayRow: View {
    let group: CardDayGroup

    var body: some View {
        HStack(spacing: 12) {
            cover

            VStack(alignment: .leading, spacing: 4) {
                Text(CardDayFormatter.title(for: group.day))
                    .font(.headline)

                Text("\(group.count) 张卡片")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(CardDayFormatter.title(for: group.day))，\(group.count) 张卡片")
        .accessibilityAddTraits(.isButton)
    }

    /// 封面用当天最新一张的缩略图。
    private var cover: some View {
        ZStack {
            Color.white

            if let image = group.cover?.thumbnailImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(3)
            } else {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 18, weight: .light))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 58, height: 58)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.black.opacity(0.08), lineWidth: 1)
        }
    }
}

