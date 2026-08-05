import AppKit
import SwiftUI
import TranlixSummarize

/// The API key, the model, and the prompt templates.
struct NotesSettingsPane: View {
    @Bindable var settings: SettingsStore

    @State private var keyField = ""
    @State private var storedKeyHint: String?
    @State private var templates: [PromptTemplate] = []
    @State private var editing: PromptTemplate?
    @State private var errorMessage: String?

    private let keys = APIKeyStore()
    private let store = TemplateStore()

    var body: some View {
        Form {
            Section("Anthropic") {
                if let hint = storedKeyHint {
                    LabeledContent("API key") {
                        HStack {
                            Text(hint)
                                .foregroundStyle(.secondary)
                            Button("Borrar", role: .destructive, action: removeKey)
                        }
                    }
                } else {
                    // A password field, so the key is not left readable on screen while the
                    // user is sharing it or walking away.
                    //
                    // Wrapped in LabeledContent with an explicit border rather than left as a
                    // bare `SecureField("sk-ant-…", …)`: inside a grouped Form, SwiftUI takes
                    // a field's first argument as its *label*, so the hint rendered as static
                    // text on the left and the editable area sat unbordered to the right of
                    // it. The field worked and looked like a disabled caption.
                    LabeledContent("API key") {
                        SecureField("sk-ant-…", text: $keyField)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 260)
                            .onSubmit(saveKey)
                    }
                    HStack {
                        Spacer()
                        Button("Guardar", action: saveKey)
                            .disabled(keyField.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }

                Picker("Modelo", selection: $settings.summaryModel) {
                    ForEach(SummaryModel.allCases) { model in
                        Text(model.displayName).tag(model)
                    }
                }

                Text("La key se guarda en el llavero del sistema, nunca en las preferencias ni en el binario. Es lo único que Tranlix manda a internet, y solo cuando confirmás el envío de una sesión.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Plantillas") {
                ForEach(templates) { template in
                    HStack {
                        Text(template.name)
                        Spacer()
                        Button("Editar") { editing = template }
                            .buttonStyle(.link)
                        if templates.count > 1 {
                            Button("Borrar", role: .destructive) { remove(template) }
                                .buttonStyle(.link)
                        }
                    }
                }
                HStack {
                    Spacer()
                    Button("Nueva plantilla", action: addTemplate)
                }
                Text("Se guardan en Application Support/Tranlix/templates.json, editables también desde afuera de la app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { reload() }
        .sheet(item: $editing) { template in
            TemplateEditor(template: template) { updated in
                save(updated)
            }
        }
        .alert(
            "No se pudo guardar",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("Entendido", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Key

    private func reload() {
        templates = store.load()
        storedKeyHint = ((try? keys.read()) ?? nil).map(Self.hint)
    }

    /// Shows enough of the key to tell two apart, and not enough to use one.
    private static func hint(_ key: String) -> String {
        key.count <= 12 ? "•••" : "\(key.prefix(8))…\(key.suffix(4))"
    }

    private func saveKey() {
        do {
            try keys.save(keyField)
            keyField = ""
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func removeKey() {
        do {
            try keys.delete()
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Templates

    private func addTemplate() {
        editing = PromptTemplate(name: "Nueva plantilla", prompt: "")
    }

    private func save(_ template: PromptTemplate) {
        var updated = templates
        if let index = updated.firstIndex(where: { $0.id == template.id }) {
            updated[index] = template
        } else {
            updated.append(template)
        }
        persist(updated)
    }

    private func remove(_ template: PromptTemplate) {
        persist(templates.filter { $0.id != template.id })
    }

    private func persist(_ updated: [PromptTemplate]) {
        do {
            try store.save(updated)
            templates = updated
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Editing one template's name and prompt.
private struct TemplateEditor: View {
    @State var template: PromptTemplate
    let onSave: (PromptTemplate) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Nombre", text: $template.name)
                .textFieldStyle(.roundedBorder)

            Text("Instrucción para el modelo. La transcripción se agrega aparte, así que no hace falta mencionarla acá.")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextEditor(text: $template.prompt)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 280)
                .overlay {
                    RoundedRectangle(cornerRadius: 6).stroke(.quaternary)
                }

            HStack {
                Spacer()
                Button("Cancelar", role: .cancel) { dismiss() }
                Button("Guardar") {
                    onSave(template)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(template.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}
