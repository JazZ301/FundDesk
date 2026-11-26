import Foundation

public enum FuturesAxis {
    public static func tickIndices(times: [Date], visible: ClosedRange<Int>) -> [Int] {
        guard !times.isEmpty, visible.lowerBound >= 0, visible.upperBound < times.count,
              visible.count > 1 else { return [] }
        let start = times[visible.lowerBound]
        let end = times[visible.upperBound]
        guard end > start else { return [visible.lowerBound, visible.upperBound] }

        let span = end.timeIntervalSince(start)
        let interval: TimeInterval = span <= 6 * 3_600 ? 3_600
            : span <= 12 * 3_600 ? 2 * 3_600 : 4 * 3_600
        let calendar = MarketClock.calendar
        let hourStart = calendar.dateInterval(of: .hour, for: start)?.start ?? start
        var target = hourStart.addingTimeInterval(interval)
        var indices = [visible.lowerBound]

        for index in visible {
            let time = times[index]
            if time >= target, target < end {
                if indices.last != index { indices.append(index) }
                repeat {
                    target = target.addingTimeInterval(interval)
                } while target <= time
            }
        }
        if indices.last != visible.upperBound {
            indices.append(visible.upperBound)
        }
        let minGap = max(2, Int((Double(visible.count) * 0.08).rounded(.up)))
        var spaced: [Int] = []
        for (position, index) in indices.enumerated() {
            if position > 0, position < indices.count - 1,
               indices[position + 1] - index < minGap {
                continue
            }
            spaced.append(index)
        }
        return spaced
    }
}
