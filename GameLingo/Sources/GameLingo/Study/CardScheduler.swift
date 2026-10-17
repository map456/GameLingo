import Foundation

/// SM-2 排程（SuperMemo 2）。
///
/// 作答對應的品質分數 q：忘記＝1、困難＝3、普通＝4、簡單＝5。
/// - q < 3（忘記）：連續答對歸零，今天稍後再出一次，間隔重算。
/// - 否則：第 1 次 1 天、第 2 次 6 天，之後＝上次間隔 × 難易係數。
/// - 難易係數 EF ← EF + 0.1 − (5 − q) × (0.08 + (5 − q) × 0.02)，最低 1.3。
enum CardScheduler {
    enum Answer: Int, CaseIterable {
        case again = 1, hard = 3, good = 4, easy = 5

        var title: String {
            switch self {
            case .again: return "忘記"
            case .hard: return "困難"
            case .good: return "普通"
            case .easy: return "簡單"
            }
        }
    }

    struct State: Equatable {
        var intervalDays: Int
        var ease: Double
        var reps: Int
        var lapses: Int
        var due: Date
    }

    static func next(_ s: State, answer: Answer, now: Date = Date()) -> State {
        let q = Double(answer.rawValue)
        var out = s
        out.ease = max(1.3, s.ease + 0.1 - (5 - q) * (0.08 + (5 - q) * 0.02))

        if answer == .again {
            out.reps = 0
            out.lapses += 1
            out.intervalDays = 0
            out.due = now.addingTimeInterval(60)  // 今天這輪結束前再出一次
            return out
        }

        out.reps += 1
        switch out.reps {
        case 1: out.intervalDays = answer == .easy ? 3 : 1
        case 2: out.intervalDays = answer == .hard ? 3 : 6
        default:
            let factor = answer == .hard ? 1.2 : (answer == .easy ? out.ease * 1.3 : out.ease)
            out.intervalDays = max(s.intervalDays + 1, Int((Double(max(1, s.intervalDays)) * factor).rounded()))
        }
        out.due = Calendar.current.startOfDay(for: now).addingTimeInterval(Double(out.intervalDays) * 86_400)
        return out
    }

    /// 按鈕上顯示「下次複習」的提示，例如「1 天」「6 天」「<1 分」
    static func preview(_ s: State, answer: Answer) -> String {
        let n = next(s, answer: answer)
        return n.intervalDays == 0 ? "<1 分" : "\(n.intervalDays) 天"
    }
}
