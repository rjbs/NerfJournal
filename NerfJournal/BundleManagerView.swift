import SwiftUI

// MARK: - BundleManagerView

struct BundleManagerView: View {
    @EnvironmentObject private var bundleStore: BundleStore

    @State private var newBundleName = ""
    @FocusState private var addBundleFieldFocused: Bool
    @State private var bundleToRename: TaskBundle? = nil
    @State private var renameText = ""

    var body: some View {
        HSplitView {
            bundleList
            bundleDetail
        }
        .task {
            try? await bundleStore.load()
        }
    }

    // A computed binding so List(selection:) drives the store's selectedBundle.
    private var selectionBinding: Binding<Int64?> {
        Binding(
            get: { bundleStore.selectedBundle?.id },
            set: { id in
                let bundle = id.flatMap { id in bundleStore.bundles.first { $0.id == id } }
                Task { try? await bundleStore.selectBundle(bundle) }
            }
        )
    }

    private var bundleList: some View {
        List(selection: selectionBinding) {
            ForEach(bundleStore.bundles) { bundle in
                Text(bundle.name)
                    .tag(bundle.id)
                    .contextMenu {
                        Button("Rename\u{2026}") {
                            renameText = bundle.name
                            bundleToRename = bundle
                        }
                        Divider()
                        Button("Delete", role: .destructive) {
                            Task { try? await bundleStore.deleteBundle(bundle) }
                        }
                    }
            }
            Section {
                TextField("Add bundle\u{2026}", text: $newBundleName)
                    .focused($addBundleFieldFocused)
                    .onSubmit { submitNewBundle() }
            }
        }
        .frame(minWidth: 180, idealWidth: 200, maxWidth: 240)
        .alert("Rename Bundle", isPresented: Binding(
            get: { bundleToRename != nil },
            set: { if !$0 { bundleToRename = nil } }
        )) {
            TextField("Bundle name", text: $renameText)
            Button("Rename") {
                if let bundle = bundleToRename {
                    let name = renameText.trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty {
                        Task { try? await bundleStore.renameBundle(bundle, to: name) }
                    }
                }
                bundleToRename = nil
                renameText = ""
            }
            Button("Cancel", role: .cancel) {
                bundleToRename = nil
                renameText = ""
            }
        }
    }

    private var bundleDetail: some View {
        Group {
            if let bundle = bundleStore.selectedBundle {
                BundleDetailView(bundle: bundle)
            } else {
                Text("Select a bundle to view its tasks.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func submitNewBundle() {
        let name = newBundleName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        Task {
            try? await bundleStore.addBundle(name: name)
            newBundleName = ""
            addBundleFieldFocused = true
        }
    }
}

// MARK: - BundleDetailView

struct BundleDetailView: View {
    @EnvironmentObject private var bundleStore: BundleStore

    let bundle: TaskBundle

    @State private var newTodoTitle = ""
    @FocusState private var addFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(bundle.name)
                    .font(.title2).bold()
                Spacer()
                Toggle("Carry tasks forward", isOn: Binding(
                    get: { bundle.todosShouldMigrate },
                    set: { val in Task { try? await bundleStore.setTodosShouldMigrate(val, for: bundle) } }
                ))
                .toggleStyle(.checkbox)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            List {
                ForEach(bundleStore.selectedBundleTodos) { todo in
                    Text(todo.title)
                        .padding(.vertical, 2)
                        .contextMenu {
                            Button("Delete", role: .destructive) {
                                Task { try? await bundleStore.deleteTodo(todo) }
                            }
                        }
                }
                .onMove { offsets, destination in
                    Task { try? await bundleStore.moveTodos(from: offsets, to: destination) }
                }

                Section {
                    TextField("Add task\u{2026}", text: $newTodoTitle)
                        .focused($addFieldFocused)
                        .onSubmit { submitNewTodo() }
                }
            }
        }
    }

    private func submitNewTodo() {
        let title = newTodoTitle.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        Task {
            try? await bundleStore.addTodo(title: title)
            newTodoTitle = ""
            addFieldFocused = true
        }
    }
}
