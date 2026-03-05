import Foundation
import GRDB

@MainActor
final class ExportGroupStore: ObservableObject {
    private let db: AppDatabase

    @Published var groups: [ExportGroup] = []

    // All group memberships keyed by groupID; available to the export menu
    // without needing to fetch on demand.
    @Published var groupMembers: [Int64: Set<Int64?>] = [:]

    // Membership set for whichever group is selected in the manager view.
    @Published var selectedGroup: ExportGroup? = nil
    @Published var selectedGroupMemberIDs: Set<Int64?> = []

    init(database: AppDatabase = .shared) {
        self.db = database
        NotificationCenter.default.addObserver(
            forName: .nerfJournalDatabaseDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                try? await self.load()
            }
        }
    }

    func load() async throws {
        let (loadedGroups, loadedMembers) = try await db.dbQueue.read { db in
            let groups = try ExportGroup.order(Column("sortOrder")).fetchAll(db)
            let allMembers = try ExportGroupMember.fetchAll(db)
            var memberMap: [Int64: Set<Int64?>] = [:]
            for group in groups {
                memberMap[group.id!] = []
            }
            for member in allMembers {
                memberMap[member.groupID, default: []].insert(member.categoryID)
            }
            return (groups, memberMap)
        }
        groups = loadedGroups
        groupMembers = loadedMembers
        if let selected = selectedGroup, let id = selected.id {
            selectedGroupMemberIDs = loadedMembers[id] ?? []
        }
    }

    func selectGroup(_ group: ExportGroup?) async throws {
        selectedGroup = group
        guard let id = group?.id else {
            selectedGroupMemberIDs = []
            return
        }
        selectedGroupMemberIDs = groupMembers[id] ?? []
    }

    func addGroup(name: String) async throws {
        let nextOrder = (groups.map(\.sortOrder).max() ?? -1) + 1
        try await db.dbQueue.write { db in
            var group = ExportGroup(id: nil, name: name, sortOrder: nextOrder)
            try group.insert(db)
        }
        try await load()
    }

    func deleteGroup(_ group: ExportGroup) async throws {
        try await db.dbQueue.write { db in
            try ExportGroup.filter(Column("id") == group.id).deleteAll(db)
            return
        }
        if selectedGroup?.id == group.id {
            selectedGroup = nil
            selectedGroupMemberIDs = []
        }
        try await load()
    }

    func renameGroup(_ group: ExportGroup, to name: String) async throws {
        try await db.dbQueue.write { db in
            try ExportGroup
                .filter(Column("id") == group.id)
                .updateAll(db, [Column("name").set(to: name)])
            return
        }
        try await load()
        if selectedGroup?.id == group.id {
            selectedGroup = groups.first { $0.id == group.id }
        }
    }

    // Adds or removes the given categoryID from group's membership.
    // Raw SQL is used for nullable-column matching to avoid ambiguity.
    func setMembership(categoryID: Int64?, included: Bool, forGroup group: ExportGroup) async throws {
        guard let groupID = group.id else { return }
        try await db.dbQueue.write { db in
            if let catID = categoryID {
                try db.execute(
                    sql: "DELETE FROM exportGroupMember WHERE groupID = ? AND categoryID = ?",
                    arguments: [groupID, catID]
                )
                if included {
                    try db.execute(
                        sql: "INSERT INTO exportGroupMember (groupID, categoryID) VALUES (?, ?)",
                        arguments: [groupID, catID]
                    )
                }
            } else {
                try db.execute(
                    sql: "DELETE FROM exportGroupMember WHERE groupID = ? AND categoryID IS NULL",
                    arguments: [groupID]
                )
                if included {
                    try db.execute(
                        sql: "INSERT INTO exportGroupMember (groupID, categoryID) VALUES (?, NULL)",
                        arguments: [groupID]
                    )
                }
            }
            return
        }
        try await load()
    }
}
