import SwiftUI

// Shared: an empty-state shown in a panel when the VM isn't running.
private struct NotRunning: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "shippingbox").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("oort isn't running").font(.title3)
            Button { model.startVM() } label: { Label("Start oort", systemImage: "play.fill") }
                .buttonStyle(.borderedProminent)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private func stateColor(_ s: String) -> Color {
    switch s { case "running": return .green; case "exited", "dead": return .secondary
    case "paused": return .orange; default: return .blue }
}

// MARK: - Dashboard

struct DashboardView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Image(systemName: model.running ? "shippingbox.fill" : "shippingbox")
                        .font(.system(size: 34)).foregroundStyle(model.running ? Color.accentColor : .secondary)
                    VStack(alignment: .leading) {
                        Text("oort").font(.title.bold())
                        Text(model.running ? (model.dockerVersion.isEmpty ? "starting…" : "Docker \(model.dockerVersion)")
                                            : "stopped").foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.running {
                        Button { model.restartVM() } label: { Label("Restart", systemImage: "arrow.clockwise") }
                        Button(role: .destructive) { model.stopVM() } label: { Label("Stop", systemImage: "stop.fill") }
                    } else {
                        Button { model.startVM() } label: { Label("Start", systemImage: "play.fill") }
                            .buttonStyle(.borderedProminent)
                    }
                }
                if model.running {
                    HStack(spacing: 14) {
                        stat("\(model.containers.filter { $0.state == "running" }.count)", "running", "shippingbox.fill")
                        stat("\(model.containers.count)", "containers", "shippingbox")
                        stat("\(model.images.count)", "images", "square.stack.3d.up")
                        stat("\(model.volumes.count)", "volumes", "externaldrive")
                        stat("\(model.machines.count)", "machines", "macwindow")
                    }
                    GroupBox("Connect the Docker CLI") {
                        HStack {
                            Text("export DOCKER_HOST=\(model.dockerHost)")
                                .font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                            Spacer()
                            Button { model.copyDockerHost() } label: { Image(systemName: "doc.on.doc") }
                        }.padding(6)
                    }
                }
                Spacer()
            }.padding(22)
        }
        .navigationTitle("Dashboard")
    }
    private func stat(_ value: String, _ label: String, _ icon: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon).foregroundStyle(.secondary)
            Text(value).font(.title2.bold())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity).padding(.vertical, 12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Containers

struct ContainersView: View {
    @EnvironmentObject var model: AppModel
    @State private var logsFor: DContainer?
    var body: some View {
        Group {
            if !model.running { NotRunning() }
            else if model.containers.isEmpty { ContentEmpty("No containers", "shippingbox") }
            else {
                List(model.containers) { c in
                    HStack(spacing: 10) {
                        Circle().fill(stateColor(c.state)).frame(width: 9, height: 9)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.name).fontWeight(.medium)
                            Text(c.image).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !c.ports.isEmpty { Text(c.ports).font(.caption.monospaced()).foregroundStyle(.secondary) }
                        Text(c.status).font(.caption).foregroundStyle(.secondary).frame(width: 130, alignment: .trailing)
                        Menu {
                            if c.state == "running" {
                                Button("Stop") { model.container(c.id, action: "stop") }
                                Button("Restart") { model.container(c.id, action: "restart") }
                            } else {
                                Button("Start") { model.container(c.id, action: "start") }
                            }
                            Button("Logs") { logsFor = c }
                            Divider()
                            Button("Remove", role: .destructive) { model.removeContainer(c.id) }
                        } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton).frame(width: 44)
                    }.padding(.vertical, 3)
                }
            }
        }
        .navigationTitle("Containers")
        .toolbar { Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") } }
        .sheet(item: $logsFor) { c in LogsSheet(container: c) }
    }
}

struct LogsSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    let container: DContainer
    @State private var text = "loading…"
    var body: some View {
        VStack(alignment: .leading) {
            HStack { Text("Logs · \(container.name)").font(.headline); Spacer()
                Button("Refresh") { load() }; Button("Done") { dismiss() } }
            ScrollView { Text(text).font(.system(.caption, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                .background(.black.opacity(0.04))
        }.padding(14).frame(width: 720, height: 460).onAppear(perform: load)
    }
    private func load() { Task.detached { let t = await model.logs(container.id)
        await MainActor.run { text = t.isEmpty ? "(no output)" : t } } }
}

// MARK: - Images

struct ImagesView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Group {
            if !model.running { NotRunning() }
            else if model.images.isEmpty { ContentEmpty("No images", "square.stack.3d.up") }
            else {
                List(model.images) { img in
                    HStack {
                        Image(systemName: "square.stack.3d.up").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(img.repoTags).fontWeight(.medium)
                            Text("\(img.id) · created \(img.created)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(img.size).font(.caption.monospaced()).foregroundStyle(.secondary)
                        Menu { Button("Remove", role: .destructive) { model.removeImage(img.id) } }
                            label: { Image(systemName: "ellipsis.circle") }
                            .menuStyle(.borderlessButton).frame(width: 44)
                    }.padding(.vertical, 3)
                }
            }
        }
        .navigationTitle("Images")
        .toolbar { Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") } }
    }
}

// MARK: - Volumes

struct VolumesView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Group {
            if !model.running { NotRunning() }
            else if model.volumes.isEmpty { ContentEmpty("No volumes", "externaldrive") }
            else {
                List(model.volumes) { v in
                    HStack {
                        Image(systemName: "externaldrive").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(v.id).fontWeight(.medium)
                            Text(v.mountpoint).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Text(v.driver).font(.caption).foregroundStyle(.secondary)
                        Menu { Button("Remove", role: .destructive) { model.removeVolume(v.id) } }
                            label: { Image(systemName: "ellipsis.circle") }
                            .menuStyle(.borderlessButton).frame(width: 44)
                    }.padding(.vertical, 3)
                }
            }
        }
        .navigationTitle("Volumes")
        .toolbar { Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") } }
    }
}

// MARK: - Machines (time-travel)

struct MachinesView: View {
    @EnvironmentObject var model: AppModel
    @State private var showNew = false
    @State private var forkSrc: Machine?
    var body: some View {
        Group {
            if !model.running { NotRunning() }
            else if model.machines.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "macwindow.on.rectangle").font(.system(size: 40)).foregroundStyle(.secondary)
                    Text("No machines").font(.title3)
                    Text("A machine is a named Linux environment you can snapshot, restore and fork.")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button { showNew = true } label: { Label("New machine", systemImage: "plus") }
                        .buttonStyle(.borderedProminent)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).padding()
            } else {
                List(model.machines) { m in
                    HStack(spacing: 10) {
                        Circle().fill(m.running ? .green : .secondary).frame(width: 9, height: 9)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(m.id).fontWeight(.medium)
                            Text(m.distro).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(m.status).font(.caption).foregroundStyle(.secondary)
                        Button("Shell") { model.machineShell(m.id) }.controlSize(.small)
                        Menu {
                            Button("Snapshot") { model.machineSnapshot(m.id) }
                            Button("Restore latest") { model.machineRestore(m.id) }
                            Button("Fork…") { forkSrc = m }
                            Divider()
                            Button("Delete", role: .destructive) { model.machineDelete(m.id) }
                        } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton).frame(width: 44)
                    }.padding(.vertical, 3)
                }
            }
        }
        .navigationTitle("Machines")
        .toolbar {
            Button { showNew = true } label: { Image(systemName: "plus") }
            Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
        }
        .sheet(isPresented: $showNew) { NewMachineSheet() }
        .sheet(item: $forkSrc) { m in ForkSheet(source: m) }
    }
}

struct NewMachineSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State private var name = ""
    @State private var distro = "ubuntu"
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New machine").font(.headline)
            Form {
                TextField("Name", text: $name)
                Picker("Distro", selection: $distro) {
                    ForEach(["ubuntu", "alpine", "debian", "fedora"], id: \.self) { Text($0) }
                }
            }
            HStack { Spacer(); Button("Cancel") { dismiss() }
                Button("Create") { model.machineCreate(name, distro: distro); dismiss() }
                    .buttonStyle(.borderedProminent).disabled(name.isEmpty) }
        }.padding(18).frame(width: 360)
    }
}

struct ForkSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    let source: Machine
    @State private var name = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Fork '\(source.id)'").font(.headline)
            Text("Instantly branch this machine into a new one (copy-on-write).")
                .font(.caption).foregroundStyle(.secondary)
            TextField("New machine name", text: $name)
            HStack { Spacer(); Button("Cancel") { dismiss() }
                Button("Fork") { model.machineFork(source.id, name); dismiss() }
                    .buttonStyle(.borderedProminent).disabled(name.isEmpty) }
        }.padding(18).frame(width: 360)
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Form {
            Section("Engine") {
                LabeledContent("Status", value: model.running ? "running" : "stopped")
                if !model.dockerVersion.isEmpty { LabeledContent("Docker", value: model.dockerVersion) }
                HStack {
                    Text("DOCKER_HOST"); Spacer()
                    Text(model.dockerHost).font(.callout.monospaced()).foregroundStyle(.secondary)
                    Button { model.copyDockerHost() } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless)
                }
            }
            Section("Startup") {
                Toggle("Start oort at login", isOn: Binding(
                    get: { model.autostart },
                    set: { model.setAutostart($0) }))
            }
            Section("Lifecycle") {
                HStack {
                    Button { model.startVM() } label: { Label("Start", systemImage: "play.fill") }.disabled(model.running)
                    Button { model.restartVM() } label: { Label("Restart", systemImage: "arrow.clockwise") }.disabled(!model.running)
                    Button(role: .destructive) { model.stopVM() } label: { Label("Stop", systemImage: "stop.fill") }.disabled(!model.running)
                }
            }
            Section { Text("oort — a lightweight, OrbStack-style Docker & Linux runtime for macOS.")
                .font(.caption).foregroundStyle(.secondary) }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
    }
}

// Shared empty-state with a title + icon.
struct ContentEmpty: View {
    let title: String; let icon: String
    init(_ title: String, _ icon: String) { self.title = title; self.icon = icon }
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 40)).foregroundStyle(.secondary)
            Text(title).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
