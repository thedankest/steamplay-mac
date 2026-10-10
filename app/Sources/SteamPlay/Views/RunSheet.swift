import SteamPlayCore
import SwiftUI

struct StepIcon: View {
    var status: EngineEvent.Step.Status
    var body: some View {
        switch status {
        case .start: ProgressView().controlSize(.small)
        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .warn: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
        case .fail: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .skip: Image(systemName: "arrow.uturn.right.circle").foregroundStyle(.secondary)
        }
    }
}

/// Progress of one operation; questions from the engine replace the step list until answered.
struct RunSheet: View {
    @Environment(AppModel.self) private var model
    @State private var showLog = false
    @State private var confirmStop = false

    var body: some View {
        if let q = model.question {
            QuestionView(question: q)
        } else if let run = model.run {
            progress(run)
        }
    }

    private func progress(_ run: RunState) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                outcomeIcon(run).font(.system(size: 26))
                VStack(alignment: .leading, spacing: 2) {
                    Text(run.title).font(.title3.weight(.semibold))
                    Text(phaseLine(run)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            List(run.steps) { s in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    StepIcon(status: s.status).frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.title)
                        if !s.detail.isEmpty {
                            Text(s.detail).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .frame(minHeight: 220)
            ForEach(run.notices, id: \.self) { n in
                Label(n, systemImage: "bell").font(.callout)
            }
            DisclosureGroup("Details", isExpanded: $showLog) {
                ScrollView {
                    Text(run.log.joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(height: 160)
            }
            HStack {
                if case .finished(.ok, _) = run.phase, run.title.hasPrefix("Installing") {
                    Text("Next: start Steam, then pick Steam Play in a Windows game's Compatibility settings.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if model.isBusy {
                    Button("Stop", role: .destructive) { confirmStop = true }
                } else {
                    if case .finished(.ok, _) = run.phase, run.title.hasPrefix("Installing") {
                        Button("Open Steam") { model.openSteam() }
                    }
                    Button("Done") { model.dismissRun() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 620)
        .confirmationDialog("Stop the installer?", isPresented: $confirmStop) {
            Button("Stop", role: .destructive) { model.stop() }
        } message: {
            Text("If Steam.app is being changed right now, the installer puts the copy from before this run back.")
        }
    }

    @ViewBuilder private func outcomeIcon(_ run: RunState) -> some View {
        switch run.phase {
        case .running, .waiting: ProgressView().controlSize(.regular)
        case .finished(let st, let code):
            if code == 0 && st != .pending { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
            else if st == .pending { Image(systemName: "clock.fill").foregroundStyle(.yellow) }
            else { Image(systemName: "xmark.octagon.fill").foregroundStyle(.red) }
        case .cancelled: Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
        }
    }

    private func phaseLine(_ run: RunState) -> String {
        switch run.phase {
        case .running: return run.current?.title ?? "Starting…"
        case .waiting: return "Waiting for your answer"
        case .cancelled(let why): return why
        case .finished(let st, let code):
            switch (st, code) {
            case (.ok?, 0): return run.resultDetail.isEmpty ? "Done." : run.resultDetail
            case (.pending?, _): return "Done. The final check runs the next time Steam starts; then press Check Again."
            case (.interrupted?, _), (_, 130): return "Stopped. Steam.app was put back as it was before this run."
            default:
                let d = run.resultDetail.isEmpty ? (run.steps.last { $0.status == .fail }?.detail ?? "") : run.resultDetail
                return "Failed\(d.isEmpty ? "" : ": \(d)") (exit \(code))."
            }
        }
    }
}

/// One engine prompt, shown with exactly the text the engine will check the answer against.
struct QuestionView: View {
    @Environment(AppModel.self) private var model
    var question: PendingQuestion

    private var c: EngineEvent.Confirm { question.confirm }

    private var title: String {
        switch c.id {
        case "plan": "Install Steam Play?"
        case "uninstall": "Uninstall Steam Play?"
        case "remove_prefixes": "Delete game prefixes?"
        case "restore_newest", "restore_valve": "Restore Steam.app?"
        case "detach": "Remove Steam Play from Steam.app?"
        case "journal_clear": "Mark the interrupted run as handled?"
        case "start_steam": "Start Steam?"
        case "d3dmetal_license": "Apple Game Porting Toolkit licence"
        default: "Continue?"
        }
    }

    private var destructive: Bool { ["uninstall", "remove_prefixes", "detach"].contains(c.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.title3.weight(.semibold))
            if c.isLicence {
                Text("D3DMetal (DirectX 12 games) comes from Apple's Game Porting Toolkit. Read and accept Apple's licence to install it. Declining stops here; nothing is changed.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                Text(question.licenceText ?? AttributedString(c.text))
                    .font(c.isLicence ? .callout : .body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(10)
            }
            .background(.background.secondary, in: .rect(cornerRadius: 8))
            .frame(minHeight: 200, maxHeight: 380)
            if let f = question.licenceFile {
                Text(f.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button(c.isLicence ? "Decline" : "Cancel", role: .cancel) { model.answer(false) }
                    .keyboardShortcut(.cancelAction)
                Button(c.isLicence ? "Accept" : (c.id == "plan" ? "Install" : "Continue"), role: destructive ? .destructive : nil) {
                    model.answer(true)
                }
                .keyboardShortcut(destructive ? nil : .defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(destructive ? .red : .accentColor)
            }
        }
        .padding(20)
        .frame(width: 620)
    }
}
