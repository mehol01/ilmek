import Foundation
import CloudKit
import Observation
import IlmekKit

/// Friends & groups on the CloudKit public database. No server of our own.
///
/// Record types (all "world readable, creator writable", CloudKit's public-DB default):
/// - `Group`       name `group_<CODE>` — name, memberLimit, banned. Only the creator can edit.
/// - `Membership`  name `member_<CODE>_<userID>` — groupCode, userID, nickname. Deterministic
///                 names make joins idempotent: retrying never creates duplicates.
/// - `Status`      name `status_<userID>` — the member's daily snapshot (see `FriendStatus`).
/// - `DayComplete` name `done_<userID>_<day>` — created once when a day is fully done; drives
///                 "friend finished today" pushes.
///
/// Required indexes (CloudKit Console → Schema → Indexes, then deploy to Production):
/// Membership.groupCode, Membership.userID, DayComplete.userID — all QUERYABLE.
@MainActor
@Observable
final class GroupStore {
    static let shared = GroupStore()

    enum Availability: Equatable { case checking, available, noAccount, unavailable(String) }

    private(set) var availability: Availability = .checking
    private(set) var cache = GroupCache.load()
    private(set) var isRefreshing = false
    private(set) var lastError: String?

    var myID: String? { cache.myID }
    var groups: [GroupInfo] { cache.groups }

    @ObservationIgnored
    private let container = CKContainer(identifier: "iCloud.com.mehol01.Ilmek")
    @ObservationIgnored
    private var db: CKDatabase { container.publicCloudDatabase }
    @ObservationIgnored
    private var bootstrapped = false
    @ObservationIgnored
    private var observingAccount = false
    @ObservationIgnored
    private var accountCheck: Task<Void, Never>?
    /// Counts my own uploads, so a refresh that started earlier doesn't put an older copy of my
    /// status back into the cache.
    @ObservationIgnored
    private var publishCount = 0

    // MARK: Read helpers

    func members(of group: GroupInfo) -> [FriendStatus?] {
        memberIDs(of: group).map { cache.statuses[$0] }
    }

    func memberIDs(of group: GroupInfo) -> [String] {
        (cache.members[group.code] ?? []).filter { !group.banned.contains($0) && blocked[$0] == nil }
    }

    // MARK: Blocking (App Store guideline 1.2)

    /// People I blocked (userID → nickname). They disappear from every group on this phone and
    /// their "finished the day" pushes stop. Nothing is sent anywhere.
    private(set) var blocked: [String: String] =
        UserDefaults.standard.dictionary(forKey: Profile.blockedKey) as? [String: String] ?? [:]

    func block(_ status: FriendStatus) {
        guard status.userID != myID else { return }
        blocked[status.userID] = status.nickname
        UserDefaults.standard.set(blocked, forKey: Profile.blockedKey)
        Task { await updateSubscriptions() }
    }

    func unblock(_ userID: String) {
        blocked[userID] = nil
        UserDefaults.standard.set(blocked, forKey: Profile.blockedKey)
        Task { await updateSubscriptions() }
    }

    func status(of userID: String) -> FriendStatus? { cache.statuses[userID] }

    var friendIDs: [String] {
        Array(Set(cache.groups.flatMap { memberIDs(of: $0) })).filter { $0 != myID }.sorted()
    }

    #if DEBUG
    /// Screenshot mode (DemoData): a fixed cache, never refreshed from or written to CloudKit.
    @ObservationIgnored private(set) var isDemo = false

    func useDemo(_ demo: GroupCache) {
        isDemo = true
        bootstrapped = true
        cache = demo
        availability = .available
    }
    #endif

    // MARK: Lifecycle

    func bootstrap() async {
        guard !bootstrapped else { return }
        bootstrapped = true
        if !observingAccount {
            observingAccount = true
            NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { _ in
                Task { @MainActor in
                    // Signed out, or a different Apple ID: look again from scratch.
                    GroupStore.shared.availability = .checking
                    GroupStore.shared.bootstrapped = false
                    await GroupStore.shared.bootstrap()
                }
            }
        }
        await refresh()   // checks the account first, and ends by publishing my status if it's behind
    }

    /// Makes sure we know who the iCloud user is. Safe to call from anywhere, any number of
    /// times: one check runs at a time, and nothing happens once the account is available.
    func ensureAccount() async {
        guard availability != .available else { return }
        if let accountCheck { await accountCheck.value; return }
        let task = Task { await checkAccount() }
        accountCheck = task
        await task.value
        accountCheck = nil
    }

    private func checkAccount() async {
        do {
            switch try await container.accountStatus() {
            case .available:
                let id = try await container.userRecordID().recordName
                if cache.myID != id {
                    // Different Apple ID than the cache: start clean.
                    cache = GroupCache()
                    cache.myID = id
                    cache.save()
                }
                availability = .available
            case .noAccount: availability = .noAccount
            case .restricted: availability = .unavailable(String(localized: "iCloud bu cihazda kısıtlı."))
            case .temporarilyUnavailable: availability = .unavailable(String(localized: "iCloud geçici olarak kullanılamıyor."))
            default: availability = .unavailable(String(localized: "iCloud durumu bilinmiyor."))
            }
        } catch {
            availability = .unavailable(Self.message(for: error))
        }
    }

    // MARK: Refresh

    /// Pulls my groups, their members and every member's status. Keeps the cache on failure.
    func refresh() async {
        #if DEBUG
        if isDemo { return }
        #endif
        // Not known yet (a background launch has no screen to start this), launched offline, or
        // iCloud was briefly unavailable: check now instead of staying stuck.
        await ensureAccount()
        guard availability == .available, let me = myID, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let uploadsBefore = publishCount
        do {
            // 1. My memberships → group codes.
            // Queries are eventually consistent: a group created seconds ago may not show up yet.
            // So the query only *adds* groups (e.g. after a reinstall); a cached group is dropped
            // only if a fetch by ID — which is strongly consistent — says my membership is gone.
            let mine = try await query("Membership", NSPredicate(format: "userID == %@", me))
            var codes = Set(mine.compactMap { $0["groupCode"] as? String })
            let membershipNickname = mine.compactMap { $0["nickname"] as? String }.first { !$0.isEmpty }
            let unseen = Set(cache.groups.map(\.code)).subtracting(codes)
            if !unseen.isEmpty {
                let ids = unseen.map { CKRecord.ID(recordName: "member_\($0)_\(me)") }
                let results = try await withRetry { try await self.db.records(for: ids) }
                for (id, result) in results {
                    if case .success = result {
                        codes.insert(String(id.recordName.dropFirst("member_".count).prefix(8)))
                    }
                }
            }

            // 2. Groups (missing = closed by owner).
            var groups: [GroupInfo] = []
            if !codes.isEmpty {
                let ids = codes.map { CKRecord.ID(recordName: "group_\($0)") }
                let results = try await withRetry { try await self.db.records(for: ids) }
                for (id, result) in results {
                    let code = String(id.recordName.dropFirst("group_".count))
                    switch result {
                    case .success(let r): groups.append(Self.group(from: r, code: code))
                    case .failure(let e as CKError) where e.code == .unknownItem:
                        try? await deleteRecord("member_\(code)_\(me)")
                    case .failure(let e): throw e
                    }
                }
            }

            // Removed by the owner → leave quietly.
            for g in groups where g.banned.contains(me) {
                try? await deleteRecord("member_\(g.code)_\(me)")
            }
            groups.removeAll { $0.banned.contains(me) }

            // 3. Members of each group.
            var members: [String: [String]] = [:]
            try await withThrowingTaskGroup(of: (String, [String]).self) { tg in
                for g in groups {
                    tg.addTask {
                        let recs = try await self.query("Membership", NSPredicate(format: "groupCode == %@", g.code))
                        return (g.code, recs.compactMap { $0["userID"] as? String }.filter(Self.isValidUserID))
                    }
                }
                // I am in every group in `groups` even if the query hasn't caught up yet.
                for try await (code, ids) in tg { members[code] = Array(Set(ids + [me])).sorted() }
            }

            // 4. Statuses of everyone.
            var statuses: [String: FriendStatus] = [:]
            let everyone = Set(members.values.flatMap { $0 })
            if !everyone.isEmpty {
                let ids = everyone.map { CKRecord.ID(recordName: "status_\($0)") }
                for chunk in ids.chunked(200) {
                    let results = try await withRetry { try await self.db.records(for: chunk) }
                    for (_, result) in results {
                        if case .success(let r) = result, let s = Self.status(from: r) { statuses[s.userID] = s }
                    }
                }
            }

            // I uploaded while this refresh was reading: my cached copy is the newer one.
            if publishCount != uploadsBefore, let newer = cache.statuses[me] { statuses[me] = newer }

            cache.groups = groups.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
            cache.members = members
            cache.statuses = statuses
            cache.refreshedAt = .now
            cache.save()
            lastError = nil

            // A reinstall wipes the nickname from this phone; the server still has it.
            Profile.restoreIfMissing(nickname: statuses[me]?.nickname ?? membershipNickname,
                                     avatar: statuses[me]?.avatar)
            await updateSubscriptions()
            // The cache now says what friends really see of me; fix it if my phone knows better.
            Task { await StatusPublisher.shared.publish() }
        } catch {
            lastError = Self.message(for: error)
        }
    }

    // MARK: Create / join / leave

    func createGroup(name: String, memberLimit: Int) async throws -> GroupInfo {
        guard availability == .available, let me = myID else { throw GroupError.noAccount }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        for _ in 0..<5 {
            let code = GroupCode.random()
            let r = CKRecord(recordType: "Group", recordID: .init(recordName: "group_\(code)"))
            r["name"] = trimmed.isEmpty ? String(localized: "Grubum") : trimmed
            r["memberLimit"] = max(0, memberLimit)
            // No "banned" yet: CloudKit can't create a list field from an empty list.
            do {
                // .ifServerRecordUnchanged on a new record fails if the code is already taken.
                try await save([r], policy: .ifServerRecordUnchanged)
            } catch let e as CKError where e.code == .serverRecordChanged {
                continue
            }
            let g = GroupInfo(code: code, name: r["name"] as? String ?? "", ownerID: me,
                              memberLimit: max(0, memberLimit), banned: [])
            try await saveMembership(code: code)
            cache.groups.append(g)
            cache.members[code] = [me]
            cache.save()
            await StatusPublisher.shared.publish(force: true)
            await refresh()
            return g
        }
        throw GroupError.other(String(localized: "Kod üretilemedi, tekrar dene."))
    }

    func join(code input: String) async throws -> GroupInfo {
        guard availability == .available, let me = myID else { throw GroupError.noAccount }
        guard let code = GroupCode.normalize(input) else { throw GroupError.codeInvalid }

        let record: CKRecord
        do {
            record = try await withRetry { try await self.db.record(for: .init(recordName: "group_\(code)")) }
        } catch let e as CKError where e.code == .unknownItem {
            throw GroupError.codeNotFound
        }
        let g = Self.group(from: record, code: code)
        if g.banned.contains(me) { throw GroupError.banned }
        if g.memberLimit > 0 {
            let count = try await query("Membership", NSPredicate(format: "groupCode == %@", code))
                .compactMap { $0["userID"] as? String }
                .filter { $0 != me && !g.banned.contains($0) }.count
            if count >= g.memberLimit { throw GroupError.full }
        }
        try await saveMembership(code: code)
        if !cache.groups.contains(where: { $0.code == code }) { cache.groups.append(g) }
        cache.save()
        await StatusPublisher.shared.publish(force: true)
        await refresh()
        return g
    }

    func leave(_ group: GroupInfo) async throws {
        guard let me = myID else { throw GroupError.noAccount }
        if group.ownerID == me {
            // Owner leaving closes the group for everyone.
            try await deleteRecord("group_\(group.code)")
        }
        try await deleteRecord("member_\(group.code)_\(me)")
        cache.groups.removeAll { $0.code == group.code }
        cache.members[group.code] = nil
        cache.save()
        await updateSubscriptions()
    }

    func update(_ group: GroupInfo, name: String? = nil, memberLimit: Int? = nil,
                ban userID: String? = nil) async throws {
        guard let me = myID, group.ownerID == me else { throw GroupError.notOwner }
        let r = try await withRetry { try await self.db.record(for: .init(recordName: "group_\(group.code)")) }
        if let name { r["name"] = name.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let memberLimit { r["memberLimit"] = max(0, memberLimit) }
        if let userID, userID != me {
            var banned = r["banned"] as? [String] ?? []
            if !banned.contains(userID) { banned.append(userID) }
            r["banned"] = banned
        }
        let saved = try await save([r], policy: .changedKeys).first ?? r
        if let i = cache.groups.firstIndex(where: { $0.code == group.code }) {
            cache.groups[i] = Self.group(from: saved, code: group.code)
            cache.save()
        }
    }

    /// Leaves every group and removes everything this user published.
    func deleteAllMyData() async throws {
        guard let me = myID else { throw GroupError.noAccount }
        for g in cache.groups { try await leave(g) }
        let mine = try await query("Membership", NSPredicate(format: "userID == %@", me))
        let dones = try await query("DayComplete", NSPredicate(format: "userID == %@", me))
        let ids = (mine + dones).map(\.recordID) + [CKRecord.ID(recordName: "status_\(me)")]
        for chunk in ids.chunked(200) {
            let results = try await withRetry {
                try await self.db.modifyRecords(saving: [], deleting: chunk, atomically: false)
            }.deleteResults
            for (_, result) in results {
                // Already gone is fine; anything else means data may still be up there.
                if case .failure(let e) = result, (e as? CKError)?.code != .unknownItem { throw e }
            }
        }
        cache = GroupCache()
        cache.myID = me
        cache.save()
        await updateSubscriptions()
    }

    private func saveMembership(code: String) async throws {
        guard let me = myID else { throw GroupError.noAccount }
        let r = CKRecord(recordType: "Membership", recordID: .init(recordName: "member_\(code)_\(me)"))
        r["groupCode"] = code
        r["userID"] = me
        r["nickname"] = Profile.nickname
        try await save([r], policy: .allKeys)
    }

    /// Saves records and fails if *any* of them was refused. `modifyRecords` reports per-record
    /// errors in its result instead of throwing, so ignoring the result hides real failures.
    @discardableResult
    private func save(_ records: [CKRecord], policy: CKModifyRecordsOperation.RecordSavePolicy) async throws -> [CKRecord] {
        try await withRetry {
            let results = try await self.db.modifyRecords(saving: records, deleting: [], savePolicy: policy,
                                                         atomically: false).saveResults
            return try records.map { r in
                guard let result = results[r.recordID] else { throw GroupError.network }
                return try result.get()
            }
        }
    }

    /// Fills in a missing nickname/avatar from what this user published before (reinstall, new phone).
    func restoreProfileIfNeeded() async {
        guard !Profile.isComplete, availability == .available, let me = myID else { return }
        if let cached = cache.statuses[me], !cached.nickname.isEmpty {
            Profile.restoreIfMissing(nickname: cached.nickname, avatar: cached.avatar)
            return
        }
        guard let record = try? await db.record(for: .init(recordName: "status_\(me)")),
              let status = Self.status(from: record) else { return }
        Profile.restoreIfMissing(nickname: status.nickname, avatar: status.avatar)
    }

    // MARK: Publishing (called by StatusPublisher)

    func publish(_ s: FriendStatus, completedToday: Bool) async throws {
        // Throwing (not returning quietly) matters: the caller must not believe this was sent.
        guard availability == .available, let me = myID, s.userID == me else { throw GroupError.noAccount }
        let r = CKRecord(recordType: "Status", recordID: .init(recordName: "status_\(me)"))
        r["userID"] = me
        r["nickname"] = s.nickname
        r["avatar"] = s.avatar
        r["day"] = s.day
        r["done"] = s.done
        r["due"] = s.due
        r["perfectStreak"] = s.perfectStreak
        r["habits"] = (try? JSONEncoder().encode(s.habits)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        r["scarf"] = s.scarf
        var saving = [r]
        if completedToday {
            let done = CKRecord(recordType: "DayComplete", recordID: .init(recordName: "done_\(me)_\(s.day)"))
            done["userID"] = me
            done["nickname"] = s.nickname
            done["day"] = s.day
            saving.append(done)
        }
        // .allKeys: the status is a full snapshot, last write wins; no conflict errors.
        try await save(saving, policy: .allKeys)
        publishCount += 1
        cache.statuses[me] = s
        cache.save()
    }

    // MARK: Push subscriptions

    @ObservationIgnored private var subscriptionKey = UserDefaults.standard.string(forKey: "groups.subKey") ?? ""

    /// One subscription for "a friend finished their day", one for "someone joined my group".
    /// Re-saved only when the friend/group set changes.
    func updateSubscriptions() async {
        guard availability == .available, let me = myID else { return }
        let friends = friendIDs
        let codes = cache.groups.map(\.code).sorted()
        let key = "\(Profile.notifyFriends)|\(friends.joined(separator: ","))|\(codes.joined(separator: ","))"
        guard key != subscriptionKey else { return }

        var save: [CKSubscription] = []
        var delete: [CKSubscription.ID] = []

        if Profile.notifyFriends && !friends.isEmpty {
            let s = CKQuerySubscription(recordType: "DayComplete",
                                        predicate: NSPredicate(format: "userID IN %@", friends),
                                        subscriptionID: "friend-day-complete",
                                        options: [.firesOnRecordCreation])
            let info = CKSubscription.NotificationInfo()
            info.alertLocalizationKey = "FRIEND_DAY_COMPLETE"
            info.alertLocalizationArgs = ["nickname"]
            info.soundName = "default"
            info.shouldSendContentAvailable = true
            s.notificationInfo = info
            save.append(s)
        } else {
            delete.append("friend-day-complete")
        }

        if Profile.notifyFriends && !codes.isEmpty {
            let s = CKQuerySubscription(recordType: "Membership",
                                        predicate: NSPredicate(format: "groupCode IN %@ AND userID != %@", codes, me),
                                        subscriptionID: "group-member-joined",
                                        options: [.firesOnRecordCreation])
            let info = CKSubscription.NotificationInfo()
            info.alertLocalizationKey = "GROUP_MEMBER_JOINED"
            info.alertLocalizationArgs = ["nickname"]
            info.shouldSendContentAvailable = true
            s.notificationInfo = info
            save.append(s)
        } else {
            delete.append("group-member-joined")
        }

        do {
            _ = try await withRetry {
                try await self.db.modifySubscriptions(saving: save, deleting: delete)
            }
            subscriptionKey = key
            UserDefaults.standard.set(key, forKey: "groups.subKey")
        } catch let e as CKError where e.code == .partialFailure
                    && (e.partialErrorsByItemID ?? [:]).values.allSatisfy({ ($0 as? CKError)?.code == .unknownItem }) {
            // Only "deleting a subscription that never existed" failed: that's fine.
            subscriptionKey = key
            UserDefaults.standard.set(key, forKey: "groups.subKey")
        } catch {
            lastError = Self.message(for: error)
        }
    }

    // MARK: CloudKit plumbing

    private func query(_ type: String, _ predicate: NSPredicate) async throws -> [CKRecord] {
        var out: [CKRecord] = []
        var (results, cursor) = try await withRetry {
            try await self.db.records(matching: CKQuery(recordType: type, predicate: predicate), resultsLimit: 200)
        }
        out += results.compactMap { try? $0.1.get() }
        while let c = cursor {
            (results, cursor) = try await withRetry { try await self.db.records(continuingMatchFrom: c) }
            out += results.compactMap { try? $0.1.get() }
        }
        return out
    }

    private func deleteRecord(_ name: String) async throws {
        do {
            _ = try await withRetry { try await self.db.deleteRecord(withID: .init(recordName: name)) }
        } catch let e as CKError where e.code == .unknownItem {
            // Already gone.
        }
    }

    /// Retries transient CloudKit errors, honouring the server's retry-after.
    private func withRetry<T>(_ op: @escaping () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            do {
                return try await op()
            } catch let e as CKError where attempt < 3 && Self.isTransient(e) {
                attempt += 1
                let wait = e.retryAfterSeconds ?? pow(2, Double(attempt))
                try await Task.sleep(for: .seconds(min(wait, 10)))
            }
        }
    }

    private static func isTransient(_ e: CKError) -> Bool {
        [.networkFailure, .networkUnavailable, .serviceUnavailable, .requestRateLimited,
         .zoneBusy].contains(e.code)
    }

    static func message(for error: Error) -> String {
        if let g = error as? GroupError { return g.localizedDescription }
        guard let e = error as? CKError else { return error.localizedDescription }
        switch e.code {
        case .networkFailure, .networkUnavailable: return GroupError.network.localizedDescription
        case .notAuthenticated: return GroupError.noAccount.localizedDescription
        case .quotaExceeded: return String(localized: "iCloud kotası dolu.")
        case .invalidArguments where e.localizedDescription.contains("queryable"):
            return String(localized: "Sunucu kurulumu eksik (index). Geliştiriciye bildir.")
        default: return e.localizedDescription
        }
    }

    // Everything below parses records written by other people's phones. Values are clamped and
    // ids checked, because a single malformed record must not be able to crash everyone in a group
    // (an invalid id, for one, makes CKRecord.ID raise an exception).

    /// CloudKit user record names: short ASCII. Anything else is not a user we can look up.
    nonisolated static func isValidUserID(_ id: String) -> Bool {
        (1...100).contains(id.utf8.count) && id.utf8.allSatisfy { c in
            (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c == 45 || c == 46
        }
    }

    private static func group(from r: CKRecord, code: String) -> GroupInfo {
        GroupInfo(code: code,
                  name: WordFilter.clean(String((r["name"] as? String ?? "").prefix(60))),
                  ownerID: r.creatorUserRecordID?.recordName == CKCurrentUserDefaultName
                      ? (GroupStore.shared.myID ?? "") : (r.creatorUserRecordID?.recordName ?? ""),
                  memberLimit: min(max(r["memberLimit"] as? Int ?? 0, 0), 100_000),
                  banned: Array((r["banned"] as? [String] ?? []).filter(isValidUserID).prefix(2000)))
    }

    private static func status(from r: CKRecord) -> FriendStatus? {
        guard let id = r["userID"] as? String, isValidUserID(id),
              r.recordID.recordName == "status_\(id)" else { return nil }
        let habits = (r["habits"] as? String).flatMap { $0.utf8.count <= 200_000 ? $0.data(using: .utf8) : nil }
            .flatMap { try? JSONDecoder().decode([SharedHabit].self, from: $0) } ?? []
        return FriendStatus(userID: id,
                            nickname: r["nickname"] as? String ?? "",
                            avatar: r["avatar"] as? String ?? "🙂",
                            day: r["day"] as? Int ?? 0,
                            done: r["done"] as? Int ?? 0,
                            due: r["due"] as? Int ?? 0,
                            perfectStreak: r["perfectStreak"] as? Int ?? 0,
                            habits: habits,
                            scarf: r["scarf"] as? Data,
                            updatedAt: r.modificationDate ?? .now).sanitized()
    }
}

extension Array {
    func chunked(_ size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
