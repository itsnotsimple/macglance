import Foundation

struct BatteryTip: Identifiable {
    enum Kind { case good, info, warning }
    let kind: Kind
    let text: String
    var id: String { text }
}

/// Advice about the battery: some from what it reports right now, some general.
/// The general rules follow Apple's own guidance for lithium-ion batteries.
enum BatteryTips {
    struct Situation {
        let battery: BatteryInfo
        let temperature: Double?               // °C
        let power: PowerUsage?
        let healthPercent: Int?                // Apple's "Maximum Capacity"
        let busiestApp: (name: String, percent: Double)?
        let lowPowerMode: Bool
    }

    /// Tips for this moment, most important first.
    static func now(_ s: Situation) -> [BatteryTip] {
        var tips: [BatteryTip] = []
        let b = s.battery

        // Heat wears a battery out faster than anything else.
        if let t = s.temperature {
            if t >= 40 {
                tips.append(.init(kind: .warning, text: tr(
                    "Батерията е гореща (\(degrees(t))). Топлината я износва най-бързо: махни Мака от меки повърхности и слънце, затвори тежките неща.",
                    "The battery is hot (\(degrees(t))). Heat wears it out fastest: move the Mac off soft surfaces and out of the sun, quit heavy apps.")))
            } else if t >= 35 {
                tips.append(.init(kind: .info, text: tr(
                    "Батерията е топла (\(degrees(t))). Нормално е под натоварване, но е по-добре да не се зарежда на горещо.",
                    "The battery is warm (\(degrees(t))). Fine under load, but better not to charge it while hot.")))
            } else {
                tips.append(.init(kind: .good, text: tr("Температурата е добра (\(degrees(t))).",
                                                        "The temperature is good (\(degrees(t))).")))
            }
        }

        // Plugged in, yet the battery is draining: the charger is too weak for what the Mac does.
        if b.isPluggedIn && b.watts < -0.5 {
            let rating = b.adapterWatts.map { " (\($0) W)" } ?? ""
            tips.append(.init(kind: .warning, text: tr(
                "Зарядното\(rating) не стига: Макът гълта повече, отколкото то дава, и батерията пада, макар и включен. Ползвай по-мощно зарядно.",
                "The charger\(rating) can't keep up: the Mac uses more than it gives, so the battery drains while plugged in. Use a stronger charger.")))
        } else if b.isPluggedIn && !b.isCharging && !b.isFull {
            tips.append(.init(kind: .good, text: tr(
                "macOS е спрял зареждането на \(b.percent)%, за да пази батерията. Спокойно остави Мака на зарядно.",
                "macOS paused charging at \(b.percent)% to protect the battery. It's fine to leave the Mac plugged in.")))
        } else if b.isPluggedIn && b.percent >= 100 {
            tips.append(.init(kind: .info, text: tr(
                "Държиш я на 100%. Ако Макът стои най-вече на зарядно, включи „Оптимизирано зареждане“: батерията ще стои около 80%, докато не ти трябва пълна.",
                "It's sitting at 100%. If the Mac is mostly plugged in, turn on Optimized Battery Charging: it holds around 80% until you need it full.")))
        }

        // On battery: how long at this pace, and what eats the most.
        if !b.isPluggedIn, let power = s.power, power.system > 0.5 {
            if let hours = hoursLeft(b, at: power.system) {
                tips.append(.init(kind: .info, text: tr(
                    "При сегашната консумация (\(watts(power.system))) ще издържи още около \(durationText(hours)).",
                    "At the current draw (\(watts(power.system))) it will last about \(durationText(hours)) more.")))
            }
            if power.other / power.system > 0.6 {
                tips.append(.init(kind: .info, text: tr(
                    "Най-много енергия отива за екрана и останалото (\(watts(power.other)) от \(watts(power.system))). По-ниската яркост удължава батерията най-много.",
                    "Most energy goes to the screen and the rest (\(watts(power.other)) of \(watts(power.system))). Lower brightness extends battery life the most.")))
            }
            if let app = s.busiestApp, app.percent >= 50 {
                tips.append(.init(kind: .info, text: tr(
                    "\(app.name) натоварва процесора (\(String(format: "%.0f", app.percent))%). Ако не ти трябва в момента, затвори го.",
                    "\(app.name) is keeping the CPU busy (\(String(format: "%.0f", app.percent))%). Quit it if you don't need it right now.")))
            }
            if !s.lowPowerMode && b.percent <= 30 {
                tips.append(.init(kind: .info, text: tr(
                    "Под 30% е: включи Low Power Mode от настройките на батерията, ще издържи доста по-дълго.",
                    "Below 30%: turn on Low Power Mode in Battery settings, it will last noticeably longer.")))
            }
        }

        // Health last: it changes slowly.
        if let health = s.healthPercent {
            if health < 80 {
                tips.append(.init(kind: .warning, text: tr(
                    "Капацитетът е \(health)%. Под 80% Apple препоръчва смяна на батерията.",
                    "Capacity is \(health)%. Below 80% Apple recommends replacing the battery.")))
            } else {
                tips.append(.init(kind: .good, text: tr(
                    "Батерията е в добро състояние: \(health)% капацитет след \(b.cycles) цикъла.",
                    "The battery is in good shape: \(health)% capacity after \(b.cycles) cycles.")))
            }
        }
        return tips
    }

    /// Energy left ÷ draw. The controller sometimes reports 0 mAh left while on battery; then the
    /// charge comes from the percentage instead. Nil when it still doesn't add up (no tip beats a wrong one).
    private static func hoursLeft(_ b: BatteryInfo, at draw: Double) -> Double? {
        let milliampHours = b.charge > 0 ? Double(b.charge) : Double(b.fullCapacity) * Double(b.percent) / 100
        let hours = milliampHours * b.voltage / 1000 / draw
        return hours.isFinite && hours >= 0.1 && hours < 100 ? hours : nil
    }

    /// "45 мин", "3 ч 20 мин".
    private static func durationText(_ hours: Double) -> String {
        let minutes = Int((hours * 60).rounded())
        return minutes < 60 ? tr("\(minutes) мин", "\(minutes) min")
                            : tr("\(minutes / 60) ч \(minutes % 60) мин", "\(minutes / 60) h \(minutes % 60) min")
    }

    /// The rules that are always true.
    static var general: [String] {
        [
            tr("Топлината е врагът №1. Най-добре е при 10–35°C: не зареждай на слънце, в кола или под одеяло.",
               "Heat is enemy number one. 10–35°C is best: don't charge in the sun, in a car or under a blanket."),
            tr("Не е нужно да я изтощаваш до 0%. Частичното зареждане е напълно наред, а дълго стоене на 0% или 100% я износва.",
               "No need to drain it to 0%. Partial charging is perfectly fine; sitting at 0% or 100% for long wears it."),
            tr("Остави „Оптимизирано зареждане“ включено (System Settings → Battery). macOS научава кога ползваш Мака и държи батерията на 80% дотогава.",
               "Keep Optimized Battery Charging on (System Settings → Battery). macOS learns when you use the Mac and holds 80% until then."),
            tr("Спокойно може да стои постоянно на зарядно: Макът сам спира зареждането, когато трябва.",
               "It's fine to keep it plugged in all the time: the Mac stops charging by itself when needed."),
            tr("При лека работа екранът харчи най-много. Автоматичната яркост и по-ниската яркост помагат най-много.",
               "During light work the screen uses the most. Auto-brightness and lower brightness help the most."),
            tr("Low Power Mode на батерия удължава времето: по-ниски честоти и по-малко работа на заден план.",
               "Low Power Mode on battery lasts longer: lower clock speeds and less background work."),
            tr("Ако Макът ще стои неизползван седмици: остави батерията на около 50% и го изключи.",
               "If the Mac will sit unused for weeks: leave the battery around 50% and shut it down."),
            tr("Цикъл = общо 100% изразходвани, например два пъти по 50%. Батерията е предвидена да пази 80% капацитет до 1000 цикъла.",
               "A cycle = 100% used in total, e.g. twice 50%. The battery is designed to keep 80% capacity up to 1000 cycles."),
        ]
    }
}
