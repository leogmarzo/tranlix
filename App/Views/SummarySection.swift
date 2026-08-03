import AppKit
import SwiftUI
import TranlixSummarize

/// Generating notes from the transcript, and the notes already generated.
///
/// The only part of the app that sends anything anywhere, which is why the confirmation is a
/// sheet showing what would be sent rather than a checkbox somebody clicks past.
struct SummarySection: View {
    @Bindable var model: SummaryViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Notas")
                .font(.headline)

            if !model.hasAPIKey {
                missingKey
            } else {
                promptPicker
                generateRow
            }

            if !model.notes.isEmpty { noteList }
        }
        .sheet(isPresented: $model.pendingConfirmation) {
            ConfirmSharingSheet(model: model)
        }
    }

    // MARK: - No key

    private var missingKey: some View {
        Label(
            "Falta la API key de Anthropic. Se carga en Ajustes → Notas.",
            systemImage: "key"
        )
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    // MARK: - Choosing the prompt

    private var promptPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $model.useFreePrompt) {
                Text("Plantilla").tag(false)
                Text("Prompt libre").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(model.isGenerating)

            if model.useFreePrompt {
                TextEditor(text: $model.freePrompt)
                    .font(.body)
                    .frame(height: 90)
                    .overlay(alignment: .topLeading) {
                        if model.freePrompt.isEmpty {
                            Text("Qué querés que haga con esta transcripción…")
                                .foregroundStyle(.tertiary)
                                .padding(.top, 8)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(.quaternary)
                    }
                    .disabled(model.isGenerating)
            } else {
                Picker("Plantilla", selection: $model.selectedTemplateID) {
                    ForEach(model.templates) { template in
                        Text(template.name).tag(Optional(template.id))
                    }
                }
                .labelsHidden()
                .disabled(model.isGenerating)
            }
        }
    }

    private var generateRow: some View {
        HStack(spacing: 12) {
            if model.isGenerating {
                ProgressView().controlSize(.small)
                Text("Escribiendo las notas…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button(action: model.generate) {
                    Label("Generar notas", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canGenerate)

                Button("Exportar transcript") { reveal(model.exportTranscript()) }
                    .buttonStyle(.link)
            }
            Spacer()
        }
    }

    // MARK: - The notes

    private var noteList: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(model.notes) { note in
                HStack(spacing: 10) {
                    Image(systemName: "doc.text")
                        .foregroundStyle(.secondary)
                    Button(note.title) { NSWorkspace.shared.open(note.url) }
                        .buttonStyle(.link)
                    Text(note.modifiedAt, format: .dateTime.day().month().hour().minute())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Mostrar") {
                        NSWorkspace.shared.activateFileViewerSelecting([note.url])
                    }
                    .buttonStyle(.link)
                }
            }
            Text("Cada corrida guarda una nota nueva; volver a generar con otro prompt no borra la anterior ni vuelve a transcribir.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
    }

    private func reveal(_ url: URL?) {
        guard let url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

/// The one-time confirmation before a session's transcript leaves the machine.
///
/// Shows what would be sent, how long it is and where it is going. The scope accepts this
/// tradeoff consciously; the sheet is what keeps it conscious instead of habitual.
private struct ConfirmSharingSheet: View {
    @Bindable var model: SummaryViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Esto sale de tu Mac", systemImage: "arrow.up.forward.app")
                .font(.title3.weight(.semibold))

            Text("Todo lo demás en Tranlix corre local. Para escribir las notas, el transcript de esta sesión se envía a la API de Anthropic. El audio no se envía nunca.")
                .fixedSize(horizontal: false, vertical: true)

            GroupBox {
                ScrollView {
                    Text(model.renderedTranscript)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(4)
                }
                .frame(height: 220)
            } label: {
                Text("Lo que se envía · ~\(model.estimatedTokens.formatted()) tokens")
                    .font(.caption)
            }

            if model.isLongSession {
                Label(
                    "Es una sesión larga. La llamada va a tardar y costar más que de costumbre.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }

            Text("Se pregunta una sola vez por sesión y queda registrado en el manifest.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancelar", role: .cancel) { dismiss() }
                Button("Enviar y generar") {
                    model.confirmAndGenerate()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
    }
}
