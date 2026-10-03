import SwiftUI

struct SettingsView: View {
    @ObservedObject private var settings = Settings.shared   // (no @State: it's a macro that needs full Xcode)
    @ObservedObject private var hotkeys = HotkeyCenter.shared
    @ObservedObject private var updater = Updater.shared
    @ObservedObject private var widgets = DesktopWidgets.shared

    private let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("MacGlance").font(.title2.weight(.semibold))
                        Text(tr("Версия", "Version") + " " + version).foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                if let release = updater.available {
                    Label {
                        Text(tr("Има нова версия: \(release.version)", "A new version is out: \(release.version)"))
                            .font(.headline)
                    } icon: {
                        Image(systemName: "arrow.down.circle.fill").foregroundStyle(.blue)
                    }
                    if !release.notes.isEmpty {
                        Text(release.notes).font(.callout).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button(tr("Обнови сега", "Update now")) { updater.install() }
                            .buttonStyle(.borderedProminent)
                            .disabled(updater.state == .downloading || updater.state == .installing)
                        updateStatus
                    }
                } else {
                    HStack {
                        Button(tr("Провери за нова версия", "Check for updates")) { updater.check() }
                            .disabled(updater.state == .checking)
                        updateStatus
                    }
                }
                Toggle(tr("Проверявай автоматично веднъж на ден", "Check automatically once a day"), isOn: $settings.autoUpdateCheck)
                HStack {
                    Text(tr("Твоята версия: ", "Your version: ") + updater.currentVersion).foregroundStyle(.secondary)
                    Spacer()
                    Link(tr("Виж в GitHub", "See on GitHub"), destination: URL(string: "https://github.com/\(Updater.repository)/releases")!)
                }
            } header: {
                Text(tr("Обновления", "Updates"))
            } footer: {
                Text(tr("Новите версии идват от GitHub (\(Updater.repository)). Всяка е подписана и се инсталира само ако подписът съвпада.",
                        "New versions come from GitHub (\(Updater.repository)). Each one is signed and only installed if the signature matches."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section(tr("Общи", "General")) {
                Picker(tr("Език", "Language"), selection: $settings.language) {
                    Text("Български").tag(Language.bg)
                    Text("English").tag(Language.en)
                }
                Toggle(tr("Пускай при включване", "Launch at login"), isOn: Binding(
                    get: { LaunchAtLogin.isEnabled },   // always the real state, in case macOS refused
                    set: { on in
                        LaunchAtLogin.isEnabled = on
                        settings.objectWillChange.send()   // redraw the view
                    }
                ))
            }

            Section {
                ForEach(WidgetKind.allCases) { kind in
                    HStack {
                        Toggle(isOn: Binding(get: { widgets.isOn(kind) }, set: { widgets.setOn(kind, $0) })) {
                            Label(kind.title, systemImage: kind.icon)
                        }
                        if let config = widgets.configs[kind] {
                            Picker("", selection: Binding(get: { config.size }, set: { widgets.setSize(kind, $0) })) {
                                ForEach(WidgetSize.allCases, id: \.self) { Text($0.title).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .fixedSize()
                        }
                    }
                }
            } header: {
                Text(tr("Уиджети на десктопа", "Desktop widgets"))
            } footer: {
                Text(tr("Стоят на десктопа зад прозорците, на всички Spaces. Мести ги с мишката; с десен бутон сменяш размера или ги махаш.",
                        "They sit on the desktop behind your windows, on every Space. Drag them anywhere; right-click to resize or remove."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach(HotkeyCenter.Action.allCases) { action in
                    HStack {
                        Text(action.title)
                        if hotkeys.taken.contains(action) {
                            Text(tr("заета от друго приложение", "taken by another app"))
                                .font(.callout).foregroundStyle(.orange)
                        }
                        Spacer()
                        Button(hotkeys.recording == action ? tr("Натисни комбинация…", "Press a shortcut…")
                                                           : hotkeys.shortcuts[action]?.display ?? tr("Запиши", "Record")) {
                            hotkeys.startRecording(action)
                        }
                        .monospacedDigit()
                        if hotkeys.shortcuts[action] != nil, hotkeys.recording != action {
                            Button { hotkeys.clear(action) } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.borderless)
                                .foregroundStyle(.secondary)
                                .help(tr("Изтрий", "Remove"))
                        }
                    }
                }
            } header: {
                Text(tr("Клавишни комбинации", "Keyboard shortcuts"))
            } footer: {
                Text(tr("Работят навсякъде, дори когато MacGlance не е отпред. Цъкни и натисни комбинация с ⌘, ⌥ или ⌃. Esc отказва, ⌫ изтрива.",
                        "They work everywhere, even when MacGlance isn't in front. Click, then press a combination with ⌘, ⌥ or ⌃. Esc cancels, ⌫ clears."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(tr("Процес, забил на 100% CPU над 5 минути", "An app stuck at 100% CPU for 5 minutes"), isOn: $settings.alertRunaway)
                Toggle(tr("Паметта не стига (жълт или червен натиск)", "Memory running short (yellow or red pressure)"), isOn: $settings.alertMemory)
                Toggle(tr("Зарядното не стига", "The charger can't keep up"), isOn: $settings.alertCharger)
                Toggle(tr("Батерията е гореща (над 40°C)", "The battery is hot (over 40°C)"), isOn: $settings.alertBatteryHot)
                Toggle(tr("Макът забавя процесора заради топлина", "The Mac slows the chip down because of heat"), isOn: $settings.alertThermal)
            } header: {
                Text(tr("Известия", "Notifications"))
            } footer: {
                Text(tr("Всяко идва веднъж за даден проблем, докато не отмине, и не по-често от на 30 минути.",
                        "Each comes once per problem, until it clears, and never more often than every 30 minutes."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker(tr("Вид", "Style"), selection: $settings.compactBar) {
                    Text(tr("Компактен (на два реда)", "Compact (two lines)")).tag(true)
                    Text(tr("Текст (на един ред)", "Text (one line)")).tag(false)
                }
                Toggle(tr("CPU натоварване", "CPU load"), isOn: $settings.showCPU)
                Toggle(tr("GPU натоварване", "GPU load"), isOn: $settings.showGPU)
                Toggle(tr("Използвана RAM", "RAM used"), isOn: $settings.showRAM)
                Toggle(tr("Ватове (цялата система)", "Watts (whole system)"), isOn: $settings.showPower)
                Toggle(tr("Мрежа (↓ сваляне, ↑ качване)", "Network (↓ down, ↑ up)"), isOn: $settings.showNetwork)
                Toggle(tr("Свободно място на диска", "Free disk space"), isOn: $settings.showDisk)
                Toggle(tr("Температура на CPU", "CPU temperature"), isOn: $settings.showTemperature)
                Picker(tr("Обновяване", "Refresh"), selection: $settings.interval) {
                    Text(tr("всяка секунда", "every second")).tag(1.0)
                    Text(tr("на 2 секунди", "every 2 seconds")).tag(2.0)
                    Text(tr("на 5 секунди", "every 5 seconds")).tag(5.0)
                }
            } header: {
                Text(tr("Горе в лентата", "In the menu bar"))
            } footer: {
                Text(tr("Мястото горе е малко, особено около „веждата“ на екрана. Ако надписът стане твърде дълъг, macOS го скрива целия. Всичко се вижда и като цъкнеш на него.",
                        "Menu bar space is tight, especially around the notch. If the text gets too long, macOS hides it completely. Everything is also in the menu when you click it."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onDisappear { hotkeys.stopRecording() }
    }

    @ViewBuilder
    private var updateStatus: some View {
        switch updater.state {
        case .checking: ProgressView().controlSize(.small)
        case .downloading: ProgressView().controlSize(.small); Text(tr("Сваляне…", "Downloading…")).foregroundStyle(.secondary)
        case .installing: ProgressView().controlSize(.small); Text(tr("Инсталиране…", "Installing…")).foregroundStyle(.secondary)
        case .upToDate: Text(tr("Имаш последната версия", "You have the latest version")).foregroundStyle(.secondary)
        case .noReleases: Text(tr("Все още няма издадени версии", "No releases published yet")).foregroundStyle(.secondary)
        case .failed(let reason): Text(reason).foregroundStyle(.orange)
        case .idle: EmptyView()
        }
    }
}
