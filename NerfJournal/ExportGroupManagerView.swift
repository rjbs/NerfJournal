import SwiftUI

struct ExportGroupManagerView: View {
    @EnvironmentObject private var exportGroupStore: ExportGroupStore
    @EnvironmentObject private var categoryStore: CategoryStore

    @State private var newGroupName = ""
    @FocusState private var addGroupFieldFocused: Bool
    @State private var groupToRename: ExportGroup? = nil
    @State private var renameText = ""

    var body: some View {
        HSplitView {
            groupList
                .frame(minWidth: 160, idealWidth: 180, maxWidth: 220)
            groupDetail
        }
        .task {
            try? await exportGroupStore.load()
            try? await categoryStore.load()
        }
    }

    private var selectionBinding: Binding<Int64?> {
        Binding(
            get: { exportGroupStore.selectedGroup?.id },
            set: { id in
                let group = id.flatMap { id in exportGroupStore.groups.first { $0.id == id } }
                Task { try? await exportGroupStore.selectGroup(group) }
            }
        )
    }

    private var groupList: some View {
        List(selection: selectionBinding) {
            ForEach(exportGroupStore.groups) { group in
                Text(group.name)
                    .tag(group.id)
                    .contextMenu {
                        Button("Rename\u{2026}") {
                            renameText = group.name
                            groupToRename = group
                        }
                        Divider()
                        Button("Delete", role: .destructive) {
                            Task { try? await exportGroupStore.deleteGroup(group) }
                        }
                    }
            }
            Section {
                TextField("Add group\u{2026}", text: $newGroupName)
                    .focused($addGroupFieldFocused)
                    .onSubmit { submitNewGroup() }
            }
        }
        .alert("Rename Group", isPresented: Binding(
            get: { groupToRename != nil },
            set: { if !$0 { groupToRename = nil } }
        )) {
            TextField("Group name", text: $renameText)
            Button("Rename") {
                if let group = groupToRename {
                    let name = renameText.trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty {
                        Task { try? await exportGroupStore.renameGroup(group, to: name) }
                    }
                }
                groupToRename = nil
                renameText = ""
            }
            Button("Cancel", role: .cancel) {
                groupToRename = nil
                renameText = ""
            }
        }
    }

    private var groupDetail: some View {
        Group {
            if let group = exportGroupStore.selectedGroup {
                List {
                    Section("Categories") {
                        ForEach(categoryStore.categories) { category in
                            Toggle(isOn: Binding(
                                get: { exportGroupStore.selectedGroupMemberIDs.contains(category.id) },
                                set: { included in
                                    Task {
                                        try? await exportGroupStore.setMembership(
                                            categoryID: category.id,
                                            included: included,
                                            forGroup: group
                                        )
                                    }
                                }
                            )) {
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(category.color.swatch)
                                        .frame(width: 10, height: 10)
                                    Text(category.name)
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                        Toggle(isOn: Binding(
                            get: { exportGroupStore.selectedGroupMemberIDs.contains(nil) },
                            set: { included in
                                Task {
                                    try? await exportGroupStore.setMembership(
                                        categoryID: nil,
                                        included: included,
                                        forGroup: group
                                    )
                                }
                            }
                        )) {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(Color.gray.opacity(0.6))
                                    .frame(width: 10, height: 10)
                                Text("Other")
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            } else {
                Text("Select a group to configure its categories.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func submitNewGroup() {
        let name = newGroupName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        Task {
            try? await exportGroupStore.addGroup(name: name)
            newGroupName = ""
            addGroupFieldFocused = true
        }
    }
}
