import Foundation

/// 一天收下的所有卡片，对应卡片页里的“集合卡片”。
///
/// 卡片页不再平铺所有卡片：一行代表一天，点进去才是这一天的沉浸式翻卡。
struct CardDayGroup: Identifiable {
    /// 当天零点（`Calendar.startOfDay`），同时用作分组 ID。
    let day: Date

    /// 当天的卡片，最新的在最前面。
    let cards: [Flashcard]

    var id: Date { day }

    var count: Int { cards.count }

    /// 集合卡片的封面：当天最新的一张。
    var cover: Flashcard? { cards.first }
}

extension FlashcardStore {

    /// 按天分组的卡片，日期从新到旧。
    ///
    /// `cards` 本身是“最新的在最前面”，所以按出现顺序建组就能保持日期倒序，
    /// 不需要再排序（同一天内部也自然是新的在前）。
    var dayGroups: [CardDayGroup] {
        let calendar = Calendar.current
        var order: [Date] = []
        var buckets: [Date: [Flashcard]] = [:]

        for card in cards {
            let day = calendar.startOfDay(for: card.createdAt)
            if buckets[day] == nil {
                order.append(day)
            }
            buckets[day, default: []].append(card)
        }

        return order.map { day in
            CardDayGroup(day: day, cards: buckets[day] ?? [])
        }
    }

    /// 某一天的全部卡片（最新的在前）。
    func cards(on day: Date) -> [Flashcard] {
        let calendar = Calendar.current
        return cards.filter { calendar.isDate($0.createdAt, inSameDayAs: day) }
    }
}

/// 卡片页顶部随机展示的激励语。
///
/// 全部是短句：顶部只占一行，太长会把列表挤下去。
enum MotivationPhrases {
    static let all: [String] = [
        "每天一张卡，单词不会忘。",
        "写下来的，才是自己的。",
        "今天的五个词，是明天的底气。",
        "慢一点没关系，别停下来。",
        "一笔一画，都是积累。",
        "记不住的时候，就再写一遍。",
        "小卡片，也能攒出大进步。",
        "今天写下的，考试会记得。",
        "单词不怕多，只怕不复习。",
        "写一遍，胜过看十遍。",
        "坚持三十天，你会感谢今天的自己。",
        "每一个生词，都是一次机会。",
        "手写的力量，比想象中大。",
        "再难的词，写三遍就熟了。",
        "今天也要认真写一张。",
        "积累从来不会骗人。"
    ]

    /// 随机取一句；数组为空时（正常不会发生）返回空串，界面自然留空。
    static func random() -> String {
        all.randomElement() ?? ""
    }
}

/// 日期分组的标题格式（“10月21日”）。
///
/// `DateFormatter` 创建成本不低，这里按“是否当年”缓存两个实例，
/// 列表滚动时不会每次新建。
enum CardDayFormatter {
    private static let sameYear: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return formatter
    }()

    private static let otherYear: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日"
        return formatter
    }()

    static func title(for day: Date) -> String {
        let calendar = Calendar.current
        let isSameYear = calendar.isDate(day, equalTo: Date(), toGranularity: .year)
        return (isSameYear ? sameYear : otherYear).string(from: day)
    }
}
