import SwiftUI
import Charts

struct GradesView: View {
    let child: Child

    var body: some View {
        Card {
            let trend = gradeTrend
            let current = trend.last?.avg ?? classAverage
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Average across classes").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    Text(current.map { "\(Int($0.rounded()))%" } ?? "–").font(.system(size: 40, weight: .bold)).monospacedDigit()
                }
                Spacer()
                if let d = delta {
                    let up = d >= 0
                    Label("\(up ? "+" : "")\(Int(d.rounded()))% in 2 wks",
                          systemImage: up ? "arrow.up.right" : "arrow.down.right")
                        .font(.caption.bold()).foregroundStyle(up ? Color(hex: "1E5B38") : Color(hex: "8A3D08"))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(up ? Color(hex: "E7F4EC") : Theme.attentionBG, in: Capsule())
                }
            }
            if trend.count >= 2 {
                Chart(trend) { p in
                    AreaMark(x: .value("Day", p.day), y: .value("Avg %", p.avg))
                        .foregroundStyle(.linearGradient(colors: [Theme.accent.opacity(0.18), Theme.accent.opacity(0.0)], startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Day", p.day), y: .value("Avg %", p.avg))
                        .foregroundStyle(Theme.accent).lineStyle(.init(lineWidth: 2.5)).interpolationMethod(.monotone)
                }
                .chartYScale(domain: yDomain(trend))
                .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) }
                .frame(height: 150)
                .accessibilityLabel("Average grade trend, now \(Int(current ?? 0)) percent")
            } else {
                Text("The trend line fills in as more work is graded.").font(.footnote).foregroundStyle(.secondary)
            }
        }

        if !recentScores.isEmpty {
            Card(title: "New scores · last 2 days") {
                ForEach(recentScores, id: \.key) { a in
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 2).fill(scoreColor(a)).frame(width: 4)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(a.title).font(.subheadline.weight(.semibold))
                            Text(a.courseName).font(.footnote).foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 1) {
                            if let e = a.pointsEarned, let p = a.pointsPossible {
                                Text("\(e.formatted())/\(p.formatted())").font(.subheadline.bold().monospacedDigit())
                            }
                            if let pct = a.percent {
                                Text("\(Int(pct.rounded()))%").font(.caption).foregroundStyle(scoreColor(a))
                            }
                        }
                    }
                    .frame(minHeight: 44)
                    if a.key != recentScores.last?.key { Divider() }
                }
            }
        }

        Card {
            ForEach(child.psCourses) { c in
                NavigationLink { CourseDetailView(child: child, course: c) } label: { CourseRow(course: c, missing: missingCount(c)) }
                if c.id != child.psCourses.last?.id { Divider() }
            }
            if child.psCourses.isEmpty { Text("No PowerSchool classes yet.").foregroundStyle(.secondary) }
        }
    }

    private func missingCount(_ c: Course) -> Int { child.missing.filter { $0.courseName == c.name }.count }

    /// Scores that arrived today or yesterday, newest first.
    private var recentScores: [Assignment] {
        let since = Calendar.current.startOfDay(for: .now).addingTimeInterval(-86_400)
        return child.assignments
            .filter { ($0.scoredAt.map { $0 >= since } ?? false) && $0.percent != nil }
            .sorted { ($0.scoredAt ?? .distantPast) > ($1.scoredAt ?? .distantPast) }
    }

    private func scoreColor(_ a: Assignment) -> Color {
        (a.percent ?? 100) >= 80 ? Theme.accent : Color(hex: "E07A1F")
    }

    /// Mean of current class percents — the "right now" number.
    private var classAverage: Double? {
        let p = child.psCourses.compactMap(\.percent)
        return p.isEmpty ? nil : p.reduce(0, +) / Double(p.count)
    }

    struct TrendPoint: Identifiable { let day: Date; let avg: Double; var id: Date { day } }

    /// A real trend built from scored PowerSchool work: the running average of all graded
    /// assignments up to each day. Gives an immediate curve instead of waiting for daily snapshots.
    private var gradeTrend: [TrendPoint] {
        let cal = Calendar.current
        let scored = child.assignments
            .filter { $0.source == .powerSchool && $0.percent != nil && $0.dueDate != nil && !$0.isExempt }
            .sorted { ($0.dueDate ?? .distantPast) < ($1.dueDate ?? .distantPast) }
        guard scored.count >= 2 else { return [] }
        var sum = 0.0, count = 0.0
        var byDay: [Date: Double] = [:]
        var order: [Date] = []
        for a in scored {
            sum += a.percent!; count += 1
            let day = cal.startOfDay(for: a.dueDate!)
            if byDay[day] == nil { order.append(day) }
            byDay[day] = sum / count
        }
        return order.map { TrendPoint(day: $0, avg: byDay[$0]!) }
    }

    private var delta: Double? {
        let t = gradeTrend
        guard let last = t.last else { return nil }
        let twoWeeksAgo = Date.now.addingTimeInterval(-14 * 86_400)
        let prior = t.last(where: { $0.day <= twoWeeksAgo }) ?? t.first
        guard let prior, abs(prior.avg - last.avg) >= 0.5 else { return nil }
        return last.avg - prior.avg
    }

    private func yDomain(_ trend: [TrendPoint]) -> ClosedRange<Double> {
        let vals = trend.map(\.avg)
        let lo = max(0, (vals.min() ?? 0) - 4)
        let hi = min(100, (vals.max() ?? 100) + 4)
        return lo...(hi > lo ? hi : lo + 1)
    }
}

struct CourseRow: View {
    let course: Course
    let missing: Int
    var body: some View {
        let low = (course.percent ?? 100) < 82
        HStack(spacing: 12) {
            Text(course.letterGrade ?? "–").font(.headline)
                .frame(width: 44, height: 44)
                .background(low ? Theme.attentionBG : Theme.accent.opacity(0.1), in: .rect(cornerRadius: 12))
                .foregroundStyle(low ? Theme.attention : Theme.accent)
            VStack(alignment: .leading, spacing: 6) {
                HStack { Text(course.name).font(.subheadline.bold()); Spacer(); Text(course.percent.map { "\(Int($0))%" } ?? "").font(.subheadline.bold().monospacedDigit()) }
                    .foregroundStyle(.primary)
                ProgressView(value: min(1, (course.percent ?? 0) / 100)).tint(low ? Color(hex: "E07A1F") : Theme.accent)
                Text([course.teacher, missing > 0 ? "\(missing) missing" : nil].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(missing > 0 ? Theme.attention : .secondary)
            }
        }
        .padding(.vertical, 6)
    }
}

struct CourseDetailView: View {
    @Environment(\.openURL) private var openURL
    let child: Child
    let course: Course
    @State private var whatIf = 85.0

    private var items: [Assignment] {
        child.assignments.filter { $0.courseName == course.name && $0.source == .powerSchool }
            .sorted { ($0.dueDate ?? .distantPast) < ($1.dueDate ?? .distantPast) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading) {
                        Text(course.name).font(.title.bold())
                        Text([course.teacher, course.period.map { "Period \($0)" }, course.room.map { "Room \($0)" }].compactMap { $0 }.joined(separator: " · "))
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack { Text(course.letterGrade ?? "–").font(.title.bold()); Text(course.percent.map { "\(Int($0))%" } ?? "").font(.subheadline.bold()) }
                        .frame(width: 84, height: 84).background(Theme.attentionBG, in: .rect(cornerRadius: 22))
                }

                Card {
                    HStack {
                        Text("Recent scores").font(.headline)
                        Spacer()
                        HStack(spacing: 10) {
                            legendDot(Theme.accent, "80%+")
                            legendDot(Color(hex: "E07A1F"), "Below 80%")
                        }
                    }
                    let recent = items.filter { $0.percent != nil || $0.isMissing }.suffix(10)
                    if recent.isEmpty {
                        Text("No scored work yet.").font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Chart(Array(recent), id: \.key) { a in
                            BarMark(x: .value("Assignment", a.title), y: .value("%", a.isMissing ? 0 : (a.percent ?? 0)))
                                .foregroundStyle((a.percent ?? 0) >= 80 ? Theme.accent : Color(hex: "E07A1F"))
                                .annotation(position: .top) { if a.isMissing { Text("Missing").font(.caption2.bold()).foregroundStyle(Theme.attention) } }
                        }
                        .chartXAxis(.hidden).chartYScale(domain: 0...100)
                        .chartYAxis { AxisMarks(values: [0, 80, 100]) }
                        .frame(height: 160)
                    }
                }

                Card(title: "How the grade is built") {
                    ForEach(categoryAverages, id: \.0) { cat, avg in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack { Text(cat).font(.subheadline.weight(.semibold)); Spacer(); Text("\(Int(avg))%").bold().monospacedDigit() }
                            ProgressView(value: avg / 100).tint(avg >= 80 ? Theme.accent : Color(hex: "E07A1F"))
                        }
                    }
                }

                let missing = items.filter(\.isMissing)
                if !missing.isEmpty {
                    Card(title: "What-if", tint: Theme.accent.opacity(0.08)) {
                        Text("If the \(missing.count) missing item\(missing.count == 1 ? "" : "s") are turned in and score \(Int(whatIf))%, the class average would be about **\(Int(whatIfPercent))%**.")
                        Slider(value: $whatIf, in: 50...100, step: 5)
                        Text("Estimate from points only. Your teacher's category weights and late policy may change the real grade.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Card(title: "All assignments") {
                    if items.isEmpty {
                        Text("No assignments posted yet.").font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(items.reversed(), id: \.key) { a in AssignmentRow(a: a, color: Color(hex: child.colorHex)) }
                }

                if let email = course.teacherEmail {
                    Button {
                        // mailto opens whatever mail app is set as default, with To pre-filled.
                        let encoded = email.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? email
                        if let url = URL(string: "mailto:\(encoded)") { openURL(url) }
                    } label: {
                        Label("Email \(course.teacher ?? "teacher")", systemImage: "envelope.fill")
                            .font(.headline).frame(maxWidth: .infinity).frame(height: 54)
                    }
                    .buttonStyle(.borderedProminent).tint(Theme.accent).clipShape(.rect(cornerRadius: 16))
                }
            }
            .padding(20)
        }
        .background(Theme.bg)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func legendDot(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var categoryAverages: [(String, Double)] {
        let scored: [Assignment] = items.filter { $0.percent != nil }
        let groups: [String: [Assignment]] = Dictionary(grouping: scored) { (a: Assignment) -> String in a.category ?? "Other" }
        var result: [(String, Double)] = []
        for (category, list) in groups {
            let percents: [Double] = list.compactMap { $0.percent }
            let total: Double = percents.reduce(0, +)
            result.append((category, total / Double(max(1, percents.count))))
        }
        return result.sorted { $0.0 < $1.0 }
    }

    private var whatIfPercent: Double {
        let scored = items.filter { $0.pointsEarned != nil && $0.pointsPossible != nil && !$0.isExempt }
        var earned = scored.compactMap(\.pointsEarned).reduce(0, +)
        var possible = scored.compactMap(\.pointsPossible).reduce(0, +)
        for m in items where m.isMissing { let p = m.pointsPossible ?? 10; earned += p * whatIf / 100; possible += p }
        return possible > 0 ? earned / possible * 100 : 0
    }
}
