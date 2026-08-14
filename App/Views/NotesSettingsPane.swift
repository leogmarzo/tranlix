import AppKit
import SwiftUI
import TranlixModel
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
                // One per kind. The app works out what a recording was; these say what to do
                // about each answer.
                ForEach(SessionKind.allCases) { kind in
                    Picker(kind.displayName, selection: template(for: kind)) {
                        ForEach(templates) { template in
                            Text(template.name).tag(Optional(template.id))
                        }
                    }
                }
                Text("Tranlix se fija solo si la grabación fue una clase, una reunión u otra cosa, y usa la plantilla que corresponda. Si se equivoca, lo corregís en el panel de notas de esa sesión.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Idioma de las notas", selection: $settings.notesLanguage) {
                    ForEach(NotesLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                Text("El transcript siempre sale en el idioma que se haya hablado. Esto decide solamente en qué idioma se escriben las notas.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("Las notas se generan solas al terminar, salvo que la grabación pase de cuatro horas — ahí hay que pedirlas a mano.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

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
        repointDanglingSlots()
    }

    private func template(for kind: SessionKind) -> Binding<UUID?> {
        Binding(
            get: { settings.templateIDs[kind] },
            set: { settings.templateIDs[kind] = $0 }
        )
    }

    /// Points every kind at a template that still exists.
    ///
    /// A picker needs a selection that exists, and a template can be deleted after being
    /// chosen for a kind. The chain falls back on its own either way, so this is about showing
    /// which template will actually run rather than an empty control that implies none will.
    private func repointDanglingSlots() {
        for kind in SessionKind.allCases {
            let current = settings.templateIDs[kind]
            guard current == nil || !templates.contains(where: { $0.id == current }) else {
                continue
            }
            settings.templateIDs[kind] = templates
                .first { $0.id == PromptTemplate.seededID(for: kind) }?.id
                ?? templates.first?.id
        }
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
            // Deleting a template can orphan the kind that pointed at it.
            repointDanglingSlots()
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
