import Foundation

/// A deleted record stays in the saved files so every device learns about the
/// delete, but it keeps only what sync needs: its identity and dates. Nothing
/// the user recorded, wrote or typed survives in it.
protocol Tombstoned: Identifiable, Hashable where ID == UUID {
    var deleted: Bool { get }
    var updatedAt: Date { get set }
    mutating func eraseContent()
}

extension Tombstoned {
    var erased: Self {
        var copy = self
        copy.eraseContent()
        return copy
    }

    var holdsDeletedContent: Bool { deleted && erased != self }
}

enum Tombstones {
    struct Merge<Record> {
        var records: [Record]
        /// The file we read still has words from something deleted, so it needs
        /// rewriting even when this device's copy didn't change.
        var remoteHoldsDeletedContent: Bool
    }

    /// Returns whether anything was erased.
    @discardableResult
    static func erase<Record: Tombstoned>(in records: inout [Record]) -> Bool {
        var changed = false
        for index in records.indices where records[index].holdsDeletedContent {
            records[index].eraseContent()
            changed = true
        }
        return changed
    }

    /// Union by identity, keeping the newest copy.
    ///
    /// With `deletionWins`, a delete on either side is final: a later edit made
    /// by a device that hadn't heard about it can't bring the record back. The
    /// result takes the later date so that older app versions, which only
    /// compare dates, accept the delete too.
    static func merge<Record: Tombstoned>(
        local: [Record], remote: [Record], deletionWins: Bool
    ) -> Merge<Record> {
        var byID: [UUID: Record] = [:]
        for record in local { byID[record.id] = record }
        for record in remote {
            guard let existing = byID[record.id] else {
                byID[record.id] = record
                continue
            }
            if deletionWins, record.deleted != existing.deleted {
                var tombstone = record.deleted ? record : existing
                tombstone.updatedAt = max(record.updatedAt, existing.updatedAt)
                byID[record.id] = tombstone
            } else if record.updatedAt >= existing.updatedAt {
                byID[record.id] = record
            }
        }

        var records = Array(byID.values)
        erase(in: &records)
        let deletedIDs = Set(records.filter(\.deleted).map(\.id))
        let stale = remote.contains { deletedIDs.contains($0.id) && (!$0.deleted || $0.holdsDeletedContent) }
        return Merge(records: records, remoteHoldsDeletedContent: stale)
    }

    /// Carries deletes into another saved copy of the same records. Returns nil
    /// when that copy has nothing to erase.
    static func applying<Record: Tombstoned>(_ current: [Record], to copy: [Record]) -> [Record]? {
        let tombstones = Dictionary(current.filter(\.deleted).map { ($0.id, $0) },
                                    uniquingKeysWith: { first, _ in first })
        var changed = false
        let updated = copy.map { record -> Record in
            if !record.deleted, let tombstone = tombstones[record.id] {
                changed = true
                return tombstone.erased
            }
            if record.holdsDeletedContent {
                changed = true
                return record.erased
            }
            return record
        }
        return changed ? updated : nil
    }
}

// Each record is rebuilt from a blank one rather than having fields cleared, so
// a field added later is erased without anyone having to remember it.

extension Recording: Tombstoned {
    mutating func eraseContent() {
        var blank = Recording(id: id, title: "", createdAt: createdAt, mode: mode)
        blank.updatedAt = updatedAt
        blank.deleted = deleted
        self = blank
    }
}

extension Brain: Tombstoned {
    mutating func eraseContent() {
        var blank = Brain(id: id, name: "", mode: mode, createdAt: createdAt)
        blank.updatedAt = updatedAt
        blank.deleted = deleted
        self = blank
    }
}

extension StudyItem: Tombstoned {
    mutating func eraseContent() {
        var blank = StudyItem(recordingID: recordingID, materialID: materialID, brainID: nil,
                              sourceTitle: "", kind: kind, prompt: "", answer: "")
        blank.id = id
        blank.createdAt = createdAt
        blank.updatedAt = updatedAt
        blank.deleted = deleted
        self = blank
    }
}

extension ExamPlan: Tombstoned {
    mutating func eraseContent() {
        var blank = ExamPlan(brainID: brainID, title: "", date: createdAt, dailyMinutes: 0)
        blank.id = id
        blank.createdAt = createdAt
        blank.updatedAt = updatedAt
        blank.deleted = deleted
        self = blank
    }
}

extension SupplementalMaterial: Tombstoned {
    mutating func eraseContent() {
        self = SupplementalMaterial(id: id, name: "", kind: kind, originalFilename: "",
                                    createdAt: createdAt, updatedAt: updatedAt, deleted: deleted)
    }
}
