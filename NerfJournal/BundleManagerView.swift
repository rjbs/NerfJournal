import SwiftUI

// MARK: - BundleManagerView

struct BundleManagerView: View {
    @EnvironmentObject private var bundleStore: BundleStore
    @EnvironmentObject private var categoryStore: CategoryStore

    @State private var newBundleName = ""
    @FocusState private var addBundleFieldFocused: Bool
    @State private var bundleToRename: TaskBundle? = nil
    @State private var renameText = ""

    @State private var newCategoryName = ""
    @FocusState private var addCategoryFieldFocused: Bool
    @State private var categoryToRename: Category? = nil
    @State private var renameCategoryText = ""

    var body: some View {
        HSplitView {
            VSplitView {
                bundleList
                categoryList
            }
            .frame(minWidth: 180, idealWidth: 200, maxWidth: 240)
            bundleDetail
        }
        .task {
            try? await bundleStore.load()
            try? await categoryStore.load()
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

    private var categoryList: some View {
        List {
            ForEach(categoryStore.categories) { category in
                HStack(spacing: 6) {
                    Circle()
                        .fill(category.color.swatch)
                        .frame(width: 10, height: 10)
                    Text(category.name)
                }
                .padding(.vertical, 2)
                .contextMenu {
                    Button("Rename\u{2026}") {
                        renameCategoryText = category.name
                        categoryToRename = category
                    }
                    Menu("Color") {
                        ForEach(CategoryColor.allCases, id: \.self) { color in
                            Button {
                                Task { try? await categoryStore.setCategoryColor(color, for: category) }
                            } label: {
                                if category.color == color {
                                    Label(color.rawValue.capitalized, systemImage: "checkmark")
                                } else {
                                    Text(color.rawValue.capitalized)
                                }
                            }
                        }
                    }
                    Divider()
                    Button("Delete", role: .destructive) {
                        Task { try? await categoryStore.deleteCategory(category) }
                    }
                }
            }
            .onMove { offsets, destination in
                Task { try? await categoryStore.moveCategories(from: offsets, to: destination) }
            }
            Section {
                TextField("Add category\u{2026}", text: $newCategoryName)
                    .focused($addCategoryFieldFocused)
                    .onSubmit { submitNewCategory() }
            }
        }
        .alert("Rename Category", isPresented: Binding(
            get: { categoryToRename != nil },
            set: { if !$0 { categoryToRename = nil } }
        )) {
            TextField("Category name", text: $renameCategoryText)
            Button("Rename") {
                if let category = categoryToRename {
                    let name = renameCategoryText.trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty {
                        Task { try? await categoryStore.renameCategory(category, to: name) }
                    }
                }
                categoryToRename = nil
                renameCategoryText = ""
            }
            Button("Cancel", role: .cancel) {
                categoryToRename = nil
                renameCategoryText = ""
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

    private func submitNewCategory() {
        let name = newCategoryName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        Task {
            try? await categoryStore.addCategory(name: name)
            newCategoryName = ""
            addCategoryFieldFocused = true
        }
    }
}

// MARK: - BundleDetailView

struct BundleDetailView: View {
    @EnvironmentObject private var bundleStore: BundleStore
    @EnvironmentObject private var categoryStore: CategoryStore

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
                            Picker("Category", selection: Binding(
                                get: { todo.categoryID },
                                set: { newID in
                                    Task { try? await bundleStore.setCategoryForTodo(todo, categoryID: newID) }
                                }
                            )) {
                                Text("None").tag(nil as Int64?)
                                ForEach(categoryStore.categories) { category in
                                    Text(category.name).tag(category.id as Int64?)
                                }
                            }
                            .pickerStyle(.inline)

                            Divider()

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
