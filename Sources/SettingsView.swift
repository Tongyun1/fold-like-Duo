import SwiftUI

struct PreviewSurface: NSViewRepresentable {
    let parameters: EffectParameters
    let progress: Double

    func makeNSView(context: Context) -> EffectMetalView {
        let view = EffectMetalView()
        view.parameters = parameters
        view.targetProgress = progress
        view.source = SampleArtwork.make()
        return view
    }

    func updateNSView(_ view: EffectMetalView, context: Context) {
        view.parameters = parameters
        view.targetProgress = progress
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var previewProgress = 0.0
    @State private var previewTask: Task<Void, Never>?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                preview
                controls
                appearance
                status
                footer
            }
            .padding(24)
        }
        .frame(width: 520, height: 760)
        .background(Color(nsColor: .windowBackgroundColor))
        .onDisappear { stopPreview() }
    }

    private var header: some View {
        HStack(spacing: 13) {
            Image(systemName: "laptopcomputer.and.arrow.down")
                .font(.system(size: 34, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.blue)
                .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text("HingeFlow").font(.system(size: 27, weight: .semibold))
                Text(L10n.text("Let the desktop follow the hinge.")).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var preview: some View {
        VStack(spacing: 10) {
            PreviewSurface(parameters: model.parameters, progress: previewProgress)
                .aspectRatio(1.6, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.white.opacity(0.12))
                }
                .accessibilityLabel(Text(L10n.text("Preview of the hinge-driven desktop effect")))
            HStack {
                Text(L10n.text("Sample preview — no screen access required"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L10n.text(previewTask == nil ? "Preview" : "Stop"),
                       systemImage: previewTask == nil ? "play.fill" : "stop.fill") {
                    previewTask == nil ? playPreview() : stopPreview()
                }
            }
        }
    }

    private var controls: some View {
        GroupBox(L10n.text("Behavior")) {
            VStack(spacing: 12) {
                toggleRow("Automatic folding", isOn: Binding(
                    get: { model.automatic },
                    set: { model.setAutomatic($0) }
                ))
                Divider()
                toggleRow("Start at login", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))
            }
            .padding(10)
        }
    }

    private var appearance: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 13) {
                HStack {
                    Text(L10n.text("Appearance")).font(.headline)
                    Spacer()
                    Button(L10n.text("Reset")) { model.resetAppearance() }.buttonStyle(.link)
                }
                sliderRow("Start angle", value: $model.triggerAngle, range: 75...115, suffix: "°")
                sliderRow("Perspective", value: $model.topNarrowing, range: 0.08...0.65)
                sliderRow("Far-edge blur", value: $model.blurRadius, range: 20...160, suffix: " pt")
                sliderRow("Darkening", value: $model.darkening, range: 0...0.45)
                sliderRow("Frost", value: $model.frost, range: 0...0.35)
            }
            .padding(10)
        }
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label(model.statusTitle, systemImage: statusIcon)
                    .font(.callout.weight(.semibold))
                Spacer()
                if let angle = model.sensorAngle {
                    Text("\(Int(angle.rounded()))°")
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            Text(model.message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.permissionNeeded {
                HStack {
                    Button(L10n.text("Request screen access")) { model.requestScreenAccess() }
                    Button(L10n.text("Open Privacy Settings")) { model.openPrivacySettings() }
                        .buttonStyle(.link)
                }
            }
            if model.reducedMotion {
                Text(L10n.text("Reduce Motion is enabled; geometry movement is softened."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        HStack {
            Label(L10n.text("Nothing is saved or uploaded"), systemImage: "lock.shield")
            Spacer()
            Text(L10n.text("⌘⇧Esc pauses instantly"))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var statusIcon: String {
        if model.permissionNeeded || model.sensorAvailability != .available { return "exclamationmark.circle" }
        if model.effectActive { return "sparkles" }
        return model.automatic ? "checkmark.circle" : "pause.circle"
    }

    private func toggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(L10n.text(title))
            Spacer()
            Toggle(L10n.text(title), isOn: isOn).labelsHidden().toggleStyle(.switch)
        }
    }

    private func sliderRow(_ title: String,
                           value: Binding<Double>,
                           range: ClosedRange<Double>,
                           suffix: String = "") -> some View {
        VStack(spacing: 4) {
            HStack {
                Text(L10n.text(title))
                Spacer()
                Text(formatted(value.wrappedValue) + suffix)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 62, alignment: .trailing)
            }
            Slider(value: value, in: range)
        }
    }

    private func formatted(_ value: Double) -> String {
        value >= 10 ? String(format: "%.0f", value) : String(format: "%.2f", value)
    }

    private func playPreview() {
        previewTask = Task { @MainActor in
            for frame in 0...260 {
                guard !Task.isCancelled else { return }
                let phase = Double(frame) / 260 * 2 * Double.pi
                previewProgress = 0.5 - 0.5 * cos(phase)
                do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
            }
            previewProgress = 0
            previewTask = nil
        }
    }

    private func stopPreview() {
        previewTask?.cancel()
        previewTask = nil
        previewProgress = 0
    }
}
