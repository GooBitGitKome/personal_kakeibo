import SwiftUI
import UIKit
import PersonalKakeiboDomain

struct CategoryButtons: View {
    let categories: [PersonalKakeiboDomain.Category]
    @Binding var selection: UUID?
    var defaultId: UUID?
    var setDefault: ((UUID) -> Void)?
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
            ForEach(categories) { category in
                let button = Button { selection = category.id } label: {
                    VStack(spacing: 4) {
                        Text(category.name).font(.callout).multilineTextAlignment(.center)
                        if category.id == defaultId { Label("初期値", systemImage: "star.fill").font(.caption2) }
                    }
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .padding(.horizontal, 4)
                    .background(selection == category.id ? Color.accentColor : Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    .foregroundStyle(selection == category.id ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == category.id ? .isSelected : [])
                if let setDefault {
                    button.simultaneousGesture(LongPressGesture(minimumDuration: 0.6).onEnded { _ in setDefault(category.id) })
                        .accessibilityAction(named: "初期ジャンルに設定") { setDefault(category.id) }
                } else { button }
            }
        }
    }
}

struct RecordedDatePicker: View {
    @Binding var date: Date
    let transactions: [PersonalKakeiboDomain.Transaction]
    @State private var showing = false
    var body: some View {
        Button { showing = true } label: {
            HStack {
                Label("日付", systemImage: "calendar")
                Spacer()
                Text(date, style: .date)
            }.frame(minHeight: 44)
        }
        .sheet(isPresented: $showing) {
            NavigationStack {
                VStack {
                    TransactionCalendar(date: $date, recordedDates: Set(transactions.map { Month.calendar.startOfDay(for: $0.occurredAt) }))
                    Label("ドットがある日は収支の入力があります", systemImage: "circle.fill").font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }.padding()
                .navigationTitle("日付を選択")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完了") { showing = false } } }
            }.presentationDetents([.large])
        }
    }
}

struct TransactionCalendar: UIViewRepresentable {
    @Binding var date: Date
    let recordedDates: Set<Date>
    var selectsVisibleMonth = false
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UICalendarView {
        let view = UICalendarView()
        view.calendar = Month.calendar
        view.timeZone = Month.calendar.timeZone
        view.locale = Locale(identifier: "ja_JP")
        view.delegate = context.coordinator
        view.selectionBehavior = UICalendarSelectionSingleDate(delegate: context.coordinator)
        view.setContentCompressionResistancePriority(.required, for: .vertical)
        return view
    }
    func updateUIView(_ view: UICalendarView, context: Context) {
        let coordinator = context.coordinator
        let changes = coordinator.parent.recordedDates.symmetricDifference(recordedDates)
        coordinator.parent = self
        let components = Month.calendar.dateComponents([.year, .month, .day], from: date)
        coordinator.isUpdating = true
        let selectedDay = Month.calendar.startOfDay(for: date)
        if let selection = view.selectionBehavior as? UICalendarSelectionSingleDate, coordinator.lastSelectedDay != selectedDay {
            coordinator.lastSelectedDay = selectedDay
            selection.setSelected(components, animated: false)
            view.setVisibleDateComponents(components, animated: false)
        }
        if !changes.isEmpty {
            view.reloadDecorations(forDateComponents: changes.map { Month.calendar.dateComponents([.year, .month, .day], from: $0) }, animated: false)
        }
        coordinator.isUpdating = false
    }
    @MainActor final class Coordinator: NSObject, UICalendarViewDelegate, UICalendarSelectionSingleDateDelegate {
        var parent: TransactionCalendar
        var isUpdating = false
        var lastSelectedDay: Date?
        init(_ parent: TransactionCalendar) { self.parent = parent }
        func calendarView(_ calendarView: UICalendarView, decorationFor dateComponents: DateComponents) -> UICalendarView.Decoration? {
            guard let date = Month.calendar.date(from: dateComponents), parent.recordedDates.contains(Month.calendar.startOfDay(for: date)) else { return nil }
            return .default(color: .systemBlue, size: .small)
        }
        func calendarView(_ calendarView: UICalendarView, didChangeVisibleDateComponentsFrom previousDateComponents: DateComponents) {
            guard parent.selectsVisibleMonth, !isUpdating,
                  let date = Month.calendar.date(from: calendarView.visibleDateComponents) else { return }
            lastSelectedDay = Month.calendar.startOfDay(for: date)
            parent.date = date
        }
        func dateSelection(_ selection: UICalendarSelectionSingleDate, didSelectDate dateComponents: DateComponents?) {
            guard !isUpdating, let dateComponents, let date = Month.calendar.date(from: dateComponents) else { return }
            lastSelectedDay = Month.calendar.startOfDay(for: date)
            parent.date = date
        }
    }
}

extension View {
    func dismissKeyboardOnSwipe() -> some View {
        scrollDismissesKeyboard(.interactively)
            .simultaneousGesture(DragGesture(minimumDistance: 24).onEnded { value in
                if value.translation.height > 35 && value.translation.height > abs(value.translation.width) {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
            })
    }
}
