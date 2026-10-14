import XCTest
@testable import FleetWatchKit

@MainActor
final class WatchAvatarTests: XCTestCase {
    var transport: FakeTransport!
    var store: WatchStore!
    var dir: URL!

    override func setUp() async throws {
        transport = FakeTransport()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = makeStore()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeStore() -> WatchStore {
        let s = WatchStore(transport: transport, defaults: UserDefaults(suiteName: UUID().uuidString)!,
                           outboxURL: dir.appendingPathComponent("o.json"),
                           avatarCache: WatchAvatarCache(directory: dir.appendingPathComponent("avatars")),
                           clock: { Fx.t0 })
        s.start()
        return s
    }

    private let png = Data((0..<300).map { UInt8($0 % 251) })
    private var digest: String { WatchCodec.digest(data: png) }

    private func botWithAvatar(digest: String?) -> WatchBot {
        WatchBot(ref: WatchBotRef(gatewayID: "mac", profileSlug: "scout"), displayName: "Scout Bot", activity: "working",
                 conversations: [WatchConversation(id: "main", title: "Main chat", isMain: true)],
                 avatar: WatchBotAvatar(shape: "hexagon", seed: "scout", colorHex: "#0A84FF", imageDigest: digest))
    }

    private func push(_ bot: WatchBot, approvals: [WatchApproval] = [], generation: Int = 1) {
        transport.push(WatchSnapshot(flavor: .dev, generation: generation, builtAt: Fx.t0, contentVisible: true,
                                     gateways: [Fx.gateway("mac", name: "Mac", bots: [bot])], attention: [], approvals: approvals))
    }

    private func answerAvatars(with data: Data?) {
        transport.handler = { req in
            guard case .avatar(let r, _) = req else { return .rejected(reason: "x") }
            return .avatar(WatchAvatarImage(digest: r.digest, data: data))
        }
    }

    // MARK: model

    func testAvatarRoundTripsAndOlderPayloadWithoutAvatarStillDecodes() throws {
        let snapshot = Fx.snapshot(gateways: [Fx.gateway("mac", name: "Mac", bots: [botWithAvatar(digest: digest)])])
        let decoded = try WatchCodec.unpack(WatchReply.self, from: WatchCodec.pack(WatchReply.snapshot(snapshot)))
        guard case .snapshot(let s) = decoded else { return XCTFail() }
        XCTAssertEqual(s.gateways[0].bots[0].avatar?.imageDigest, digest)

        let legacy = Fx.snapshot(gateways: [Fx.gateway("mac", name: "Mac", bots: [Fx.bot("mac", "scout", name: "Scout")])])
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as! [String: Any]
        var gateways = json["gateways"] as! [[String: Any]]
        var bots = gateways[0]["bots"] as! [[String: Any]]
        bots[0].removeValue(forKey: "avatar")
        gateways[0]["bots"] = bots
        json["gateways"] = gateways
        let back = try JSONDecoder().decode(WatchSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(back.gateways[0].bots[0].avatar)
    }

    func testBudgetTrimKeepsAvatar() {
        let trimmed = WatchSnapshotBudget.trimmed(Fx.snapshot(gateways: [Fx.gateway("mac", name: "Mac", bots: [botWithAvatar(digest: digest)])]))
        XCTAssertEqual(trimmed.gateways[0].bots[0].avatar?.renderShape, "hexagon")
    }

    func testUnknownShapeAndBadColorDegradeSafely() {
        let a = WatchBotAvatar(shape: "sigil-7", seed: "x", colorHex: "blue")
        XCTAssertEqual(a.renderShape, "squircle")
        XCTAssertNil(a.rgb)
        XCTAssertEqual(WatchBotAvatar(shape: "drop", seed: "x", colorHex: "#FF0000").rgb?.red, 1)
    }

    func testInitialsAndActivityVocabulary() {
        XCTAssertEqual(botWithAvatar(digest: nil).initials, "SB")
        XCTAssertEqual(WatchBotActivityKind(rawActivity: "usingTool"), .busy)
        XCTAssertEqual(WatchBotActivityKind(rawActivity: "needsAttention"), .needsAttention)
        XCTAssertEqual(WatchBotActivityKind(rawActivity: "somethingNew"), .unknown, "unrecognised is never shown as idle")
    }

    func testImageValidityRequiresMatchingDigestAndBudget() {
        XCTAssertTrue(WatchAvatarImage(digest: digest, data: png).isValid)
        XCTAssertFalse(WatchAvatarImage(digest: WatchCodec.digest("other"), data: png).isValid)
        let big = Data(count: WatchAvatarImage.maxBytes + 1)
        XCTAssertFalse(WatchAvatarImage(digest: WatchCodec.digest(data: big), data: big).isValid)
        XCTAssertFalse(WatchAvatarImage(digest: digest, data: nil).isValid)
    }

    // MARK: cache

    func testCacheRejectsTamperedFilesAndPathLikeDigests() throws {
        let cache = WatchAvatarCache(directory: dir.appendingPathComponent("c"))
        XCTAssertTrue(cache.store(WatchAvatarImage(digest: digest, data: png)))
        XCTAssertEqual(cache.load(digest), png)
        try Data("swapped".utf8).write(to: dir.appendingPathComponent("c").appendingPathComponent(digest))
        XCTAssertNil(cache.load(digest), "bytes that don't match their digest are never shown")
        XCTAssertNil(cache.load("../../etc/passwd"))
        XCTAssertFalse(cache.store(WatchAvatarImage(digest: "../x", data: png)))
    }

    func testCacheEvictsOldestBeyondCapacity() throws {
        let cache = WatchAvatarCache(directory: dir.appendingPathComponent("c"), capacity: 2)
        var digests: [String] = []
        for i in 0..<3 {
            let data = Data([UInt8(i), 1, 2, 3])
            let d = WatchCodec.digest(data: data)
            digests.append(d)
            XCTAssertTrue(cache.store(WatchAvatarImage(digest: d, data: data)))
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(1000 + i))],
                                                  ofItemAtPath: dir.appendingPathComponent("c").appendingPathComponent(d).path)
        }
        let cache2 = WatchAvatarCache(directory: dir.appendingPathComponent("c"), capacity: 2)
        let extra = Data([9, 9])
        cache2.store(WatchAvatarImage(digest: WatchCodec.digest(data: extra), data: extra))
        XCTAssertNil(cache2.load(digests[0]))
        XCTAssertNil(cache2.load(digests[1]))
        XCTAssertNotNil(cache2.load(digests[2]))
    }

    // MARK: store

    func testFetchesThumbnailOnceThenServesFromMemoryAndDisk() async {
        answerAvatars(with: png)
        let bot = botWithAvatar(digest: digest)
        push(bot)
        await store.loadAvatar(for: bot)
        await store.loadAvatar(for: bot)
        XCTAssertEqual(store.avatarData(for: bot), png)
        let avatarRequests = transport.sent.filter { if case .avatar = $0 { return true }; return false }
        XCTAssertEqual(avatarRequests.count, 1)
        guard case .avatar(let r, let flavor)? = avatarRequests.first else { return XCTFail() }
        XCTAssertEqual(r, WatchAvatarRequest(gatewayID: "mac", profileSlug: "scout", digest: digest))
        XCTAssertEqual(flavor, .dev)

        // A relaunch reads it from disk with no request.
        transport.sent = []
        store = makeStore()
        push(bot)
        XCTAssertEqual(store.avatarData(for: bot), png)
        await store.loadAvatar(for: bot)
        XCTAssertTrue(transport.sent.isEmpty)
    }

    func testWrongOrMissingImageIsNeverShownAndNotRequestedAgain() async {
        answerAvatars(with: Data("not the advertised image".utf8))
        let bot = botWithAvatar(digest: digest)
        push(bot)
        await store.loadAvatar(for: bot)
        XCTAssertNil(store.avatarData(for: bot))
        await store.loadAvatar(for: bot)
        XCTAssertEqual(transport.sent.count, 1)
    }

    func testNoAvatarRequestWhileIPhoneUnreachableOrWithoutDigest() async {
        answerAvatars(with: png)
        transport.linkState = .phoneUnreachable
        store.onLinkForTest(.phoneUnreachable)
        let bot = botWithAvatar(digest: digest)
        push(bot)
        await store.loadAvatar(for: bot)
        await store.loadAvatar(for: botWithAvatar(digest: nil))
        XCTAssertTrue(transport.sent.isEmpty)
        XCTAssertNil(store.avatarData(for: bot))
    }

    // MARK: arrivals and selection

    func testApprovalArrivalCountsOnlyGenuinelyNewApprovals() {
        let a = Fx.approval(gateway: "mac", request: "r1"), b = Fx.approval(gateway: "mac", request: "r2")
        let bot = botWithAvatar(digest: nil)
        push(bot, approvals: [a], generation: 1)
        XCTAssertEqual(store.approvalArrivalCount, 0, "approvals already pending at launch don't buzz")
        push(bot, approvals: [a], generation: 2)
        XCTAssertEqual(store.approvalArrivalCount, 0)
        push(bot, approvals: [a, b], generation: 3)
        XCTAssertEqual(store.approvalArrivalCount, 1)
        push(bot, approvals: [b], generation: 4)
        push(bot, approvals: [a, b], generation: 5)
        XCTAssertEqual(store.approvalArrivalCount, 1, "one that drops out of the list and returns isn't new")
    }

    func testSelectBotPrefersReportedMainChatElseOverview() {
        let bot = botWithAvatar(digest: nil)
        push(bot)
        store.select(bot)
        XCTAssertEqual(store.selection, .init(gatewayID: "mac", profileSlug: "scout", conversationID: "main"))
        let noMain = WatchBot(ref: bot.ref, displayName: "Scout", activity: "idle", conversations: [])
        store.select(noMain)
        XCTAssertEqual(store.selection, .init(gatewayID: "mac", profileSlug: "scout"))
    }

    func testBotLookupsAndPerBotApprovals() {
        let mine = Fx.approval(gateway: "mac", request: "r1")
        let other = WatchApproval(gatewayID: "mac", gatewayName: "Mac", profileSlug: "atlas", botName: "Atlas", sessionID: "s",
                                  sessionLabel: "x", requestID: "r9", commandPreview: "ls", commandDigest: WatchCodec.digest("ls"),
                                  requiresFullReview: false, choices: ["once"], observedAt: Fx.t0)
        let bot = botWithAvatar(digest: nil)
        push(bot, approvals: [mine, other])
        XCTAssertEqual(store.botEntries.map(\.id), ["mac#scout"])
        XCTAssertEqual(store.bot(gatewayID: "mac", profileSlug: "scout")?.displayName, "Scout Bot")
        XCTAssertNil(store.bot(gatewayID: "mac", profileSlug: nil))
        XCTAssertEqual(store.approvals(for: bot).map(\.requestID), ["r1"])
    }
}
