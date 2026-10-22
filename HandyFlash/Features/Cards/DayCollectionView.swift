import SwiftUI
import UIKit

/// 某一天的卡片集合：沉浸式左右滑动 + 轻点翻面。
///
/// 三种状态：
/// - 默认：整页翻卡（`TabView` + `PageTabViewStyle(indexDisplayMode: .never)`，不显示页码点）；
/// - 点右上角“选择”：进入多选，勾选后一次性删除所选；
/// - 卡片被删光：自动退回卡片页。
struct DayCollectionView: View {
    /// 这一天的零点（与 `CardDayGroup.day` 一致）。
    let day: Date

    @ObservedObject var store: FlashcardStore

    @Environment(\.dismiss) private var dismiss

    /// 当前翻到第几张。
    @State private var index = 0

    /// 是否处于多选删除模式。
    @State private var isSelecting = false

    /// 多选模式下勾选的卡片。
    @State private var selection: Set<UUID> = []

    /// 是否正在确认“删除所选”。
    @State private var showsDeleteConfirmation = false

    /// 当天卡片，最新的在最前面。
    private var cards: [Flashcard] { store.cards(on: day) }

    var body: some View {
        Group {
            if cards.isEmpty {
                emptyState
            } else if isSelecting {
                selectionList
            } else {
                pager
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .onChange(of: cards.count) { newCount in
            // 删光了就退回卡片页；删到当前页之后就把页码夹回来。
            if newCount == 0 {
                dismiss()
            } else if index >= newCount {
                index = newCount - 1
            }
        }
        .confirmationDialog(
            "删除选中的 \(selection.count) 张卡片？",
            isPresented: $showsDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                store.remove(ids: Array(selection))
                selection.removeAll()
                isSelecting = false
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除后无法恢复，其它日期的卡片不受影响。")
        }
    }

    // MARK: - 沉浸式翻卡

    private var pager: some View {
        TabView(selection: $index) {
            ForEach(Array(cards.enumerated()), id: \.element.id) { pair in
                FlashcardPageView(card: pair.element)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .tag(pair.offset)
            }
        }
        .tabViewStyle(PageTabViewStyle(indexDisplayMode: .never))
        .overlay(alignment: .bottom) {
            pagerFooter
                .padding(.bottom, 10)
                .allowsHitTesting(false)
        }
    }

    /// 底部状态条：第几张 / 共几张 + 翻面提示。
    private var pagerFooter: some View {
        HStack(spacing: 8) {
            Text("\(min(index + 1, max(cards.count, 1))) / \(cards.count)")
                .font(.footnote.monospacedDigit())

            Label("轻点卡片翻面", systemImage: "hand.tap")
                .font(.footnote)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .accessibilityElement(children: .combine)
    }

    // MARK: - 多选删除

    private var selectionList: some View {
        List {
            ForEach(cards) { card in
                HStack(spacing: 12) {
                    thumbnail(for: card)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(Self.timeFormatter.string(from: card.createdAt))
                            .font(.subheadline)

                        Text("当天第 \(orderNumber(of: card)) 张")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 0)

                    Image(systemName: selection.contains(card.id) ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(selection.contains(card.id) ? Color.accentColor : Color.secondary)
                }
                .padding(.vertical, 2)
                .contentShape(Rectangle())
                .onTapGesture {
                    toggleSelection(of: card)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        // 左滑单张删除：不用进多选也能删。
                        selection.remove(card.id)
                        store.remove(id: card.id)
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    "\(Self.timeFormatter.string(from: card.createdAt))，"
                        + (selection.contains(card.id) ? "已选中" : "未选中")
                )
                .accessibilityAddTraits(.isButton)
            }
        }
        .listStyle(.insetGrouped)
    }

    private func thumbnail(for card: Flashcard) -> some View {
        ZStack {
            Color.white

            if let image = card.thumbnailImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(2)
            } else {
                Image(systemName: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 46, height: 46)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.black.opacity(0.08), lineWidth: 1)
        }
    }

    private func orderNumber(of card: Flashcard) -> Int {
        (cards.firstIndex { $0.id == card.id } ?? 0) + 1
    }

    // MARK: - 空状态

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)

            Text("这一天的卡片都删完了")
                .font(.headline)

            Button("返回卡片页") {
                dismiss()
            }
            .buttonStyle(.bordered)
            .padding(.top, 4)
        }
        .padding(32)
    }

    // MARK: - 工具栏

    private var navigationTitle: String {
        if isSelecting {
            return selection.isEmpty ? "选择卡片" : "已选 \(selection.count) 张"
        }
        return CardDayFormatter.title(for: day)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button(isSelecting ? "完成" : "选择") {
                toggleSelectionMode()
            }
            .disabled(cards.isEmpty)
            .accessibilityLabel(isSelecting ? "完成选择" : "选择卡片")
        }

        if isSelecting {
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) {
                    showsDeleteConfirmation = true
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(selection.isEmpty)
                .accessibilityLabel("删除所选")
            }
        }
    }

    // MARK: - 动作

    private func toggleSelectionMode() {
        withAnimation(.easeInOut(duration: 0.2)) {
            isSelecting.toggle()
            if !isSelecting {
                // 退出多选时清空勾选，下次进来不会残留。
                selection.removeAll()
            }
        }
    }

    private func toggleSelection(of card: Flashcard) {
        if selection.contains(card.id) {
            selection.remove(card.id)
        } else {
            selection.insert(card.id)
        }
    }

    /// 多选列表里的时间：同一天，只显示时分即可。
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

struct DayCollectionView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationContainer {
            DayCollectionView(
                day: Calendar.current.startOfDay(for: Date()),
                store: FlashcardStore(
                    rootURL: FileManager.default.temporaryDirectory
                        .appendingPathComponent("HandyFlashPreview", isDirectory: true)
                )
            )
        }
    }
}
