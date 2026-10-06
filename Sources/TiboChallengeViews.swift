import AppKit
import SwiftUI

private struct ChallengePalette {
    let dark: Bool
    var paper: Color { dark ? Color(red:0.085,green:0.071,blue:0.055) : Color(red:1,green:0.957,blue:0.867) }
    var ink: Color { dark ? Color(red:0.96,green:0.92,blue:0.83) : Color(red:0.15,green:0.125,blue:0.10) }
    var muted: Color { ink.opacity(0.65) }
    var sheet: Color { dark ? Color(red:0.15,green:0.135,blue:0.11) : Color(red:1,green:0.992,blue:0.969) }
    var accent: Color { Color(red:1,green:0.36,blue:0.17) }
    var sun: Color { dark ? Color(red:0.78,green:0.60,blue:0.18) : Color(red:1,green:0.847,blue:0.30) }
    var mint: Color { dark ? Color(red:0.42,green:0.65,blue:0.36) : Color(red:0.725,green:0.902,blue:0.65) }
    func color(for record: ChallengeRecord) -> Color {
        if record.status == .cancelled { return muted.opacity(0.3) }
        return record.kind == .improvement ? mint : accent
    }
}

struct ChallengeDeskCalendar: View {
    let day: Int
    var date: String? = nil
    var clock: String? = nil
    var width: CGFloat = 140
    @Environment(\.colorScheme) private var colorScheme
    private var palette: ChallengePalette { .init(dark:colorScheme == .dark) }
    var body: some View {
        VStack(spacing:0) {
            if let date {
                Text(date).font(.system(size:width*0.09,weight:.semibold)).lineLimit(1).minimumScaleFactor(0.8)
                    .padding(.top,width*0.08).frame(maxWidth:.infinity).frame(height:width*0.30)
                    .foregroundStyle(Color.black.opacity(0.85)).background(palette.sun)
            } else { palette.sun.frame(height:width*0.26) }
            VStack(spacing:width*0.04) {
                if width > 80 { Text(L("挑战日", "Challenge day")).font(.system(size:width*0.085)) }
                Text(String(format:"%02d",day)).font(.system(size:width*0.39,weight:.heavy,design:.rounded)).monospacedDigit()
                if let clock {
                    Rectangle().fill(palette.muted.opacity(0.35)).frame(height:0.5).padding(.horizontal,12)
                    Text(clock).font(.system(size:width*0.13,weight:.bold,design:.rounded)).monospacedDigit()
                }
                if width > 80 { Text(L("美西时间", "Pacific time")).font(.system(size:width*0.07)).foregroundStyle(palette.muted) }
            }.padding(.vertical,width*0.065).frame(maxWidth:.infinity).background(palette.sheet)
        }.foregroundStyle(palette.ink).frame(width:width)
            .clipShape(RoundedRectangle(cornerRadius:width*0.05))
            .overlay(RoundedRectangle(cornerRadius:width*0.05).stroke(palette.ink,lineWidth:width > 80 ? 1.5 : 1))
            .overlay(alignment:.top) {
                HStack(spacing:width*0.35) {
                    ForEach(0..<2) { _ in Capsule().fill(palette.sheet).frame(width:width*0.045,height:width*0.16)
                        .overlay(Capsule().stroke(palette.ink,lineWidth:1)) }
                }.offset(y:-width*0.05)
            }
            .shadow(color:palette.ink.opacity(0.3),radius:0,x:width > 80 ? 2 : 1,y:width > 80 ? 3 : 1)
            .accessibilityElement(children:.ignore).accessibilityLabel(L("挑战第 \(day) 天，美西时间", "Challenge day \(day), Pacific time"))
    }
}

struct TiboChallengeEntry: View {
    @ObservedObject var manager: TiboChallengeManager
    let now: Date
    var open: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        if manager.enabled && manager.document.isActive(at:now) {
            let document = manager.document
            let day = document.currentDay(at:now)
            let weekStart = ((day-1)/7)*7+1
            let palette = ChallengePalette(dark:colorScheme == .dark)
            let entryAccent = colorScheme == .dark ? Color(red:1,green:0.48,blue:0.30) : Color(red:0.72,green:0.20,blue:0.04)
            Button(action:open) {
                VStack(alignment:.leading,spacing:10) {
                    HStack(spacing:8) {
                        ChallengeDeskCalendar(day:day,width:24).accessibilityHidden(true)
                        (Text(L("Tibo 的 ", "Tibo’s ")) + Text(L("28 天挑战", "28-day challenge")).foregroundColor(entryAccent))
                            .font(.system(size:12,weight:.semibold)).lineLimit(1).minimumScaleFactor(0.9)
                        Spacer(minLength:4)
                        Text("\(day)/28").font(.system(size:10)).monospacedDigit().foregroundStyle(Color.primary)
                        Image(systemName:"chevron.right").font(.system(size:10)).foregroundStyle(Color.primary)
                    }
                    HStack(spacing:5) {
                        ForEach(weekStart..<weekStart+7,id:\.self) { number in
                            let record = document.records(for:number).first
                            Text("\(number)").font(.system(size:11,weight:number == day ? .semibold : .regular)).monospacedDigit()
                                .foregroundStyle(record?.status == .completed ? Color.black : Color.primary)
                                .frame(maxWidth:.infinity).frame(height:24)
                                .background(record.map { palette.color(for:$0).opacity($0.status == .scheduled ? 0.45 : 0.8) } ?? .clear,
                                            in:RoundedRectangle(cornerRadius:5))
                                .overlay(RoundedRectangle(cornerRadius:5).stroke(palette.muted.opacity(0.35),style:StrokeStyle(lineWidth:0.7,dash:record == nil ? [2,2] : [])))
                        }
                        Text(L("共 28 天", "28 days")).font(.system(size:10)).foregroundStyle(Color.primary).fixedSize()
                    }
                    if let latest = document.records.last {
                        HStack(spacing:5) {
                            Circle().fill(palette.color(for:latest)).frame(width:6,height:6)
                            Text("\(latest.category) · \(latest.title.localized)").font(.system(size:11,weight:.medium)).lineLimit(1).truncationMode(.tail)
                        }.foregroundStyle(Color.primary)
                    } else { Text(L("等待首条记录", "Waiting for the first record")).font(.system(size:11)).foregroundStyle(Color.primary) }
                }.padding(12).foregroundStyle(Color.primary)
                    .background(Color.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:12))
                    .contentShape(RoundedRectangle(cornerRadius:12))
            }.buttonStyle(.plain).help(L("打开活动窗口查看全部记录", "Open the activity window to view all records"))
                .accessibilityLabel("\(document.title.localized), \(day)/28")
        }
    }
}

struct TiboChallengeSettingsEntry: View {
    @ObservedObject var manager: TiboChallengeManager
    var now: Date
    var open: () -> Void
    var body: some View {
        if manager.enabled {
            VStack(alignment:.leading,spacing:16) {
                Text(L("活动记录", "Activity records")).font(.system(size:13,weight:.semibold)).padding(.top,8)
                Button(action:open) {
                    HStack(spacing:12) {
                        Image(systemName:"calendar").font(.system(size:22)).foregroundStyle(.secondary).accessibilityHidden(true)
                        VStack(alignment:.leading,spacing:4) {
                            Text(manager.document.title.localized).font(.system(size:13,weight:.medium))
                            Text(manager.document.periodText).font(.system(size:11)).foregroundStyle(.secondary)
                                .fixedSize(horizontal:false,vertical:true)
                        }
                        Spacer(minLength:8)
                        Text(manager.document.isActive(at:now) ? L("进行中", "Active") : now < manager.document.start ? L("未开始", "Upcoming") : L("已结束", "Ended"))
                            .font(.system(size:11)).foregroundStyle(.secondary)
                        Image(systemName:"chevron.right").font(.system(size:11)).foregroundStyle(.secondary)
                    }.frame(minHeight:48).contentShape(Rectangle())
                }.buttonStyle(.plain).help(L("查看活动进展与历史记录", "View activity progress and history"))
            }
        }
    }
}


struct TiboChallengeView: View {
    static let size = NSSize(width:960,height:760)
    static let minimumSize = NSSize(width:780,height:600)
    @ObservedObject var manager: TiboChallengeManager
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedDay = 0
    private var palette: ChallengePalette { .init(dark:colorScheme == .dark) }
    private var document: TiboChallengeDocument { manager.document }
    private var currentDay: Int { document.currentDay(at:manager.windowNow) }
    private var selection: Int { selectedDay == 0 ? min(28,max(1,currentDay)) : selectedDay }
    private var sourceClock: String {
        let formatter = DateFormatter();formatter.locale = .autoupdatingCurrent;formatter.timeZone = document.calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("jmm")
        return formatter.string(from:manager.windowNow)
    }
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:30) {
                HStack(alignment:.top,spacing:28) {
                    VStack(alignment:.leading,spacing:16) {
                        (Text(L("Tibo 的 ", "Tibo’s ")) + Text(L("28 天挑战", "28-day challenge")).foregroundColor(palette.accent))
                            .font(.system(size:34,weight:.heavy,design:.rounded)).fixedSize(horizontal:false,vertical:true)
                            .accessibilityAddTraits(.isHeader)
                        Text(document.statement.localized).font(.system(size:14)).lineSpacing(5).foregroundStyle(palette.muted)
                            .fixedSize(horizontal:false,vertical:true)
                        sourceLink("@thsottiaux ↗",url:document.sourceURL)
                    }.frame(maxWidth:.infinity,alignment:.leading)
                    ChallengeDeskCalendar(day:min(28,max(1,currentDay)),date:document.dateText(for:min(28,max(1,currentDay)),includeWeekday:true),clock:sourceClock)
                        .rotationEffect(.degrees(1.5)).padding(.top,6)
                }
                HStack(alignment:.top,spacing:26) {
                    VStack(alignment:.leading,spacing:16) {
                        Text(L("28 天进度", "28-day progress")).font(.system(size:24,weight:.bold,design:.rounded)).accessibilityAddTraits(.isHeader)
                        LazyVGrid(columns:Array(repeating:GridItem(.flexible(),spacing:7),count:7),spacing:8) {
                            ForEach(1...28,id:\.self) { day in dayCell(day) }
                        }
                        HStack(spacing:16) {
                            legend(palette.mint,L("产品改进", "Improvement"))
                            legend(palette.accent,L("额度重置", "Quota reset"))
                        }.padding(.top,3)
                    }.frame(maxWidth:.infinity,alignment:.leading)
                    Rectangle().fill(palette.muted.opacity(0.35)).frame(width:0.7)
                    VStack(alignment:.leading,spacing:16) {
                        Text(L("第 \(String(format:"%02d",selection)) 天", "Day \(String(format:"%02d",selection))"))
                            .font(.system(size:26,weight:.bold,design:.rounded)).accessibilityAddTraits(.isHeader)
                        Text(document.dateText(for:selection,includeWeekday:true)).font(.system(size:14,weight:.medium)).foregroundStyle(palette.muted)
                        let records = document.records(for:selection)
                        if records.isEmpty {
                            Text(selection > currentDay ? L("未开始", "Not started") : L("暂无记录", "No records yet"))
                                .font(.system(size:14)).foregroundStyle(palette.muted).padding(.top,8)
                        }
                        ForEach(records) { record in
                            recordDetail(record)
                            if record.id != records.last?.id { Divider().overlay(palette.muted.opacity(0.2)) }
                        }
                    }.frame(width:280,alignment:.leading)
                }.fixedSize(horizontal:false,vertical:true)
            }.padding(36).frame(maxWidth:.infinity,alignment:.leading)
        }.foregroundStyle(palette.ink).background(palette.paper)
            .frame(minWidth:Self.minimumSize.width,minHeight:Self.minimumSize.height)
    }
    private func dayCell(_ day: Int) -> some View {
        let records = document.records(for:day)
        let record = records.first
        return Button { selectedDay = day } label: {
            VStack(spacing:6) {
                Text(String(format:"%02d",day)).font(.system(size:15,weight:.bold,design:.rounded)).monospacedDigit()
                Text(document.dateText(for:day)).font(.system(size:9)).lineLimit(1).minimumScaleFactor(0.75)
                HStack(spacing:3) {
                    ForEach(records) { record in Circle().fill(palette.color(for:record)).frame(width:4,height:4) }
                }.frame(height:4)
            }.frame(maxWidth:.infinity).frame(height:66)
                .background(record.map { palette.color(for:$0).opacity($0.status == .scheduled ? 0.35 : 0.75) } ?? .clear,in:RoundedRectangle(cornerRadius:7))
                .overlay(RoundedRectangle(cornerRadius:7).stroke(selection == day ? palette.ink : palette.muted.opacity(0.35),
                    style:StrokeStyle(lineWidth:selection == day ? 1.5 : 0.7,dash:record == nil && selection != day ? [3,3] : [])))
                .contentShape(RoundedRectangle(cornerRadius:7))
        }.buttonStyle(.plain).accessibilityLabel(L("第 \(day) 天，\(document.dateText(for:day))", "Day \(day), \(document.dateText(for:day))"))
            .accessibilityValue(records.map(\.category).joined(separator:", "))
            .accessibilityAddTraits(selection == day ? .isSelected : [])
    }
    private func recordDetail(_ record: ChallengeRecord) -> some View {
        VStack(alignment:.leading,spacing:14) {
            Text(record.category).font(.system(size:11,weight:.medium)).padding(.horizontal,9).padding(.vertical,4)
                .background(palette.color(for:record).opacity(0.8),in:Capsule())
            Text(record.title.localized).font(.system(size:22,weight:.bold,design:.rounded)).foregroundStyle(palette.accent)
                .fixedSize(horizontal:false,vertical:true)
            Text(record.body.localized).font(.system(size:14)).lineSpacing(5).foregroundStyle(palette.muted).fixedSize(horizontal:false,vertical:true)
            sourceLink(L("查看原帖 ↗", "View original post ↗"),url:record.sourceURL)
            Text(record.timeDescription).font(.system(size:10)).foregroundStyle(palette.muted).fixedSize(horizontal:false,vertical:true)
        }
    }
    private func legend(_ color: Color,_ label: String) -> some View {
        HStack(spacing:6) { RoundedRectangle(cornerRadius:3).fill(color).frame(width:10,height:10);Text(label).font(.system(size:11)) }
            .foregroundStyle(palette.muted)
    }
    private func sourceLink(_ title: String,url: URL) -> some View {
        Button { if TiboChallengeDocument.validSource(url) { NSWorkspace.shared.open(url) } } label: {
            Text(title).font(.system(size:13)).underline().foregroundStyle(palette.ink)
        }.buttonStyle(.plain).help(url.absoluteString)
    }
}
