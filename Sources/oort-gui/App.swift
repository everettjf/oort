import SwiftUI

// oort — a complete native SwiftUI app: a windowed control panel (Dashboard,
// Containers, Images, Volumes, Machines, Settings) plus a menu-bar item for
// quick status + start/stop. Talks to the engine through the projected Docker
// socket and the `oort` CLI (see Engine.swift). The OrbStack-style surface, in
// ~no dependencies.

enum Panel: String, CaseIterable, Identifiable {
    case dashboard = "Dashboard"
    case containers = "Containers"
    case images = "Images"
    case volumes = "Volumes"
    case machines = "Machines"
    case settings = "Settings"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .dashboard: return "gauge.with.dots.needle.67percent"
        case .containers: return "shippingbox"
        case .images: return "square.stack.3d.up"
        case .volumes: return "externaldrive"
        case .machines: return "macwindow.on.rectangle"
        case .settings: return "gearshape"
        }
    }
}

// Run as a regular windowed app (the MenuBarExtra would otherwise make us a
// menu-bar-only accessory with no main window). Activate so the window comes up
// front on launch.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldHandleReopen(_ s: NSApplication, hasVisibleWindows v: Bool) -> Bool {
        if !v { s.windows.first?.makeKeyAndOrderFront(nil) }; return true
    }
}

@main
struct OortGUIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    @State private var panel: Panel? = .dashboard

    var body: some Scene {
        WindowGroup("Oort") {
            NavigationSplitView {
                List(Panel.allCases, selection: $panel) { p in
                    Label(p.rawValue, systemImage: p.icon).tag(p)
                }
                .navigationSplitViewColumnWidth(min: 175, ideal: 195, max: 230)
                .safeAreaInset(edge: .bottom) { SidebarStatus().environmentObject(model) }
            } detail: {
                Group {
                    switch panel ?? .dashboard {
                    case .dashboard:  DashboardView()
                    case .containers: ContainersView()
                    case .images:     ImagesView()
                    case .volumes:    VolumesView()
                    case .machines:   MachinesView()
                    case .settings:   SettingsView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(minWidth: 840, minHeight: 540)
            .environmentObject(model)
        }

        MenuBarExtra("Oort", systemImage: model.running ? "shippingbox.fill" : "shippingbox") {
            if model.running {
                Text(model.dockerVersion.isEmpty ? "starting…" : "Docker \(model.dockerVersion)")
                Text(model.dockerInfo).foregroundStyle(.secondary)
                Divider()
                Button("Stop oort") { model.stopVM() }
                Button("Restart oort") { model.restartVM() }
                Button("Copy DOCKER_HOST") { model.copyDockerHost() }
            } else {
                Text("oort: stopped")
                Divider()
                Button("Start oort") { model.startVM() }
            }
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
    }
}

// Sidebar footer: VM state + one-click start/stop.
struct SidebarStatus: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            HStack(spacing: 7) {
                Circle().fill(model.running ? .green : .secondary).frame(width: 9, height: 9)
                Text(model.running ? (model.starting ? "starting…" : "running") : "stopped")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            if model.running {
                Button { model.stopVM() } label: { Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity) }
            } else {
                Button { model.startVM() } label: { Label("Start", systemImage: "play.fill").frame(maxWidth: .infinity) }
            }
        }
        .padding(10)
        .buttonStyle(.bordered)
    }
}
