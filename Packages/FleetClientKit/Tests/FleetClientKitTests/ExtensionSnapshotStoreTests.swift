import XCTest
@testable import FleetClientKit

final class ExtensionSnapshotStoreTests: XCTestCase {
    private var directory: URL!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FleetClientKitTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var store: ExtensionSnapshotStore {
        ExtensionSnapshotStore(fileURL: directory.appendingPathComponent("snapshot.json"))
    }

    private func handle(_ n: Int) -> String {
        // Deterministic synthetic 22-char base64url handles.
        String(format: "handle%017d", n)
    }

    private func gateway(_ n: Int, label: String = "Workstation") -> ExtensionSnapshot.Gateway {
        ExtensionSnapshot.Gateway(
            handle: handle(n), displayLabel: label,
            runningCount: 2, needsAttentionCount: 1, onlineCount: 3, updatedAt: now)
    }

    private func snapshot(_ gateways: [ExtensionSnapshot.Gateway]? = nil) -> ExtensionSnapshot {
        ExtensionSnapshot(generatedAt: now, contentHidden: false, gateways: gateways ?? [gateway(1), gateway(2, label: "Laptop")])
    }

    // MARK: round trip / atomicity

    func testWriteThenReadRoundTrips() throws {
        let original = snapshot()
        try store.write(original)
        XCTAssertEqual(try store.read(), original)
    }

    func testReadWithNoFileIsNil() throws {
        XCTAssertNil(try store.read())
    }

    func testRewriteReplacesAtomicallyAndLeavesNoTempFiles() throws {
        try store.write(snapshot([gateway(1)]))
        try store.write(snapshot([gateway(1), gateway(2)]))
        XCTAssertEqual(try store.read()?.gateways.count, 2)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(files, ["snapshot.json"], "atomic replace leaves only the final file")
    }

    func testRejectedWriteKeepsThePreviousSnapshot() throws {
        let good = snapshot([gateway(1)])
        try store.write(good)
        var bad = snapshot([gateway(1)])
        bad.gateways[0].displayLabel = ""
        XCTAssertThrowsError(try store.write(bad))
        XCTAssertEqual(try store.read(), good)
    }

    func testEncodingIsDeterministic() throws {
        let a = try ExtensionSnapshotStore.encode(snapshot())
        let b = try ExtensionSnapshotStore.encode(snapshot())
        XCTAssertEqual(a, b)
    }

    func testRemoveIsIdempotent() throws {
        try store.write(snapshot())
        try store.remove()
        XCTAssertNil(try store.read())
        XCTAssertNoThrow(try store.remove())
    }

    // MARK: size cap

    func testOversizedSnapshotIsRejectedBeforeWriting() throws {
        // Within per-field bounds but, with the gateway cap lifted by direct
        // construction, larger than the cap.
        let many = (0..<ExtensionSnapshot.maximumGatewayCount).map {
            gateway($0, label: String(repeating: "W", count: ExtensionSnapshot.maximumLabelLength))
        }
        // 32 gateways stay under the cap by design...
        XCTAssertNoThrow(try store.write(snapshot(many)))
        let encoded = try ExtensionSnapshotStore.encode(snapshot(many))
        XCTAssertLessThan(encoded.count, ExtensionSnapshotStore.maximumEncodedBytes)
        // ...and more than the gateway cap is refused structurally.
        let tooMany = (0..<(ExtensionSnapshot.maximumGatewayCount + 1)).map { gateway($0) }
        XCTAssertThrowsError(try store.write(snapshot(tooMany))) {
            XCTAssertEqual($0 as? ExtensionSnapshotError, .invalid(.tooManyGateways))
        }
    }

    func testWriteOverTheByteCapIsRejectedAndKeepsThePreviousFile() throws {
        let url = directory.appendingPathComponent("capped.json")
        let small = ExtensionSnapshotStore(fileURL: url)
        try small.write(snapshot([gateway(1)]))
        let tiny = ExtensionSnapshotStore(fileURL: url, byteCap: 100)
        XCTAssertThrowsError(try tiny.write(snapshot())) {
            XCTAssertEqual($0 as? ExtensionSnapshotError, .tooLarge)
        }
        XCTAssertEqual(try small.read(), snapshot([gateway(1)]), "rejected write left the old file intact")
    }

    func testOversizedFileOnDiskIsRejectedByTheReader() throws {
        let url = directory.appendingPathComponent("snapshot.json")
        try Data(repeating: 0x20, count: ExtensionSnapshotStore.maximumEncodedBytes + 1).write(to: url)
        XCTAssertThrowsError(try ExtensionSnapshotStore(fileURL: url).read()) {
            XCTAssertEqual($0 as? ExtensionSnapshotError, .tooLarge)
        }
    }

    // MARK: versioning / corruption

    func testNewerSchemaVersionFailsClosed() throws {
        let url = directory.appendingPathComponent("snapshot.json")
        let json = #"{"schemaVersion":2,"generatedAt":"2027-01-15T08:00:00Z","contentHidden":false,"gateways":[],"futureField":{"a":1}}"#
        try Data(json.utf8).write(to: url)
        XCTAssertThrowsError(try ExtensionSnapshotStore(fileURL: url).read()) {
            XCTAssertEqual($0 as? ExtensionSnapshotError, .unsupportedSchemaVersion(2))
        }
    }

    func testOlderOrMissingSchemaVersionFailsClosed() throws {
        let url = directory.appendingPathComponent("snapshot.json")
        try Data(#"{"schemaVersion":0,"generatedAt":"2027-01-15T08:00:00Z","contentHidden":false,"gateways":[]}"#.utf8).write(to: url)
        XCTAssertThrowsError(try ExtensionSnapshotStore(fileURL: url).read()) {
            XCTAssertEqual($0 as? ExtensionSnapshotError, .unsupportedSchemaVersion(0))
        }
        try Data(#"{"generatedAt":"2027-01-15T08:00:00Z"}"#.utf8).write(to: url)
        XCTAssertThrowsError(try ExtensionSnapshotStore(fileURL: url).read()) {
            XCTAssertEqual($0 as? ExtensionSnapshotError, .corrupt)
        }
    }

    func testWriterRefusesToWriteAnotherSchemaVersion() {
        var future = snapshot()
        future.schemaVersion = ExtensionSnapshot.currentSchemaVersion + 1
        XCTAssertThrowsError(try store.write(future)) {
            XCTAssertEqual($0 as? ExtensionSnapshotError, .unsupportedSchemaVersion(2))
        }
    }

    func testUnknownKeysAtTheCurrentVersionAreIgnored() throws {
        let url = directory.appendingPathComponent("snapshot.json")
        let json = """
        {"schemaVersion":1,"generatedAt":"2027-01-15T08:00:00Z","contentHidden":false,"extra":true,
         "gateways":[{"handle":"\(handle(1))","displayLabel":"A","runningCount":1,"needsAttentionCount":0,"onlineCount":1,"extra":"x"}]}
        """
        try Data(json.utf8).write(to: url)
        XCTAssertEqual(try ExtensionSnapshotStore(fileURL: url).read()?.gateways.first?.displayLabel, "A")
    }

    func testCorruptFilesAreReportedNotCrashed() throws {
        let url = directory.appendingPathComponent("snapshot.json")
        for garbage in ["", "{", "[]", "null", "\u{0}\u{1}\u{2}", #"{"schemaVersion":1}"#] {
            try Data(garbage.utf8).write(to: url)
            XCTAssertThrowsError(try ExtensionSnapshotStore(fileURL: url).read(), "garbage: \(garbage)") {
                XCTAssertEqual($0 as? ExtensionSnapshotError, .corrupt)
            }
        }
    }

    func testOutOfBoundsContentOnDiskIsTreatedAsCorrupt() throws {
        let url = directory.appendingPathComponent("snapshot.json")
        let json = """
        {"schemaVersion":1,"generatedAt":"2027-01-15T08:00:00Z","contentHidden":false,
         "gateways":[{"handle":"host.example.test:9119","displayLabel":"A","runningCount":1,"needsAttentionCount":0,"onlineCount":1}]}
        """
        try Data(json.utf8).write(to: url)
        XCTAssertThrowsError(try ExtensionSnapshotStore(fileURL: url).read()) {
            XCTAssertEqual($0 as? ExtensionSnapshotError, .corrupt)
        }
    }

    // MARK: validation

    func testHostnameShapedHandlesAreRejected() {
        for bad in ["host.example.test", "10.0.0.1:9119", "short", "with space 0123456789", String(repeating: "a", count: 65)] {
            var s = snapshot([gateway(1)])
            s.gateways[0].handle = bad
            XCTAssertThrowsError(try s.validate(), bad) {
                XCTAssertEqual($0 as? ExtensionSnapshotError, .invalid(.badHandle))
            }
        }
    }

    func testDuplicateHandlesLabelsAndCountsAreValidated() {
        var dup = snapshot([gateway(1), gateway(1)])
        XCTAssertThrowsError(try dup.validate()) {
            XCTAssertEqual($0 as? ExtensionSnapshotError, .invalid(.duplicateHandle))
        }
        dup = snapshot([gateway(1, label: String(repeating: "a", count: 41))])
        XCTAssertThrowsError(try dup.validate()) {
            XCTAssertEqual($0 as? ExtensionSnapshotError, .invalid(.badLabel))
        }
        dup = snapshot([gateway(1, label: "line\nbreak")])
        XCTAssertThrowsError(try dup.validate()) {
            XCTAssertEqual($0 as? ExtensionSnapshotError, .invalid(.badLabel))
        }
        var negative = snapshot([gateway(1)])
        negative.gateways[0].runningCount = -1
        XCTAssertThrowsError(try negative.validate()) {
            XCTAssertEqual($0 as? ExtensionSnapshotError, .invalid(.countOutOfRange))
        }
        negative.gateways[0].runningCount = ExtensionSnapshot.maximumCount + 1
        XCTAssertThrowsError(try negative.validate())
    }

    func testErrorsNeverEchoSnapshotContent() {
        var s = snapshot([gateway(1, label: "Very Private Name")])
        s.gateways[0].handle = "secret.host.example.test"
        XCTAssertThrowsError(try store.write(s)) { error in
            XCTAssertFalse("\(error)".contains("secret.host"))
            XCTAssertFalse("\(error)".contains("Private"))
        }
    }

    // MARK: contentHidden

    func testBuilderRedactsNamesWhenAppLockIsEnabled() throws {
        let inputs = [
            ExtensionSnapshotBuilder.GatewayInput(
                handle: handle(1), displayName: "Tony's MacBook", runningCount: 1, needsAttentionCount: 0, onlineCount: 2),
            ExtensionSnapshotBuilder.GatewayInput(
                handle: handle(2), displayName: "Render box", runningCount: 0, needsAttentionCount: 4, onlineCount: 1),
        ]
        let locked = ExtensionSnapshotBuilder.make(gateways: inputs, appLockEnabled: true, now: now)
        XCTAssertTrue(locked.contentHidden)
        XCTAssertEqual(locked.gateways.map(\.displayLabel), ["Gateway 1", "Gateway 2"])
        XCTAssertEqual(locked.gateways.map(\.needsAttentionCount), [0, 4], "coarse counts remain")
        try store.write(locked)
        let raw = String(decoding: try Data(contentsOf: store.fileURL), as: UTF8.self)
        XCTAssertFalse(raw.contains("MacBook"))
        XCTAssertFalse(raw.contains("Render"))

        let open = ExtensionSnapshotBuilder.make(gateways: inputs, appLockEnabled: false, now: now)
        XCTAssertFalse(open.contentHidden)
        XCTAssertEqual(open.gateways.map(\.displayLabel), ["Tony's MacBook", "Render box"])
    }

    func testHiddenSnapshotCannotCarryNamesOnDisk() {
        var s = snapshot()
        s.contentHidden = true   // labels still carry names
        XCTAssertThrowsError(try store.write(s)) {
            XCTAssertEqual($0 as? ExtensionSnapshotError, .invalid(.hiddenSnapshotCarriesLabels))
        }
        XCTAssertNoThrow(try store.write(s.redactedForLock()))
    }

    func testBuilderBoundsInputs() {
        let inputs = (0..<50).map {
            ExtensionSnapshotBuilder.GatewayInput(
                handle: handle($0), displayName: "  Name\nwith \t breaks   and   spaces  " + String(repeating: "z", count: 100),
                runningCount: -5, needsAttentionCount: 1_000_000, onlineCount: 3)
        }
        let built = ExtensionSnapshotBuilder.make(gateways: inputs, appLockEnabled: false, now: now)
        XCTAssertEqual(built.gateways.count, ExtensionSnapshot.maximumGatewayCount)
        XCTAssertNoThrow(try built.validate())
        let first = built.gateways[0]
        XCTAssertEqual(first.runningCount, 0)
        XCTAssertEqual(first.needsAttentionCount, ExtensionSnapshot.maximumCount)
        XCTAssertLessThanOrEqual(first.displayLabel.count, ExtensionSnapshot.maximumLabelLength)
        XCTAssertFalse(first.displayLabel.contains("\n"))
        XCTAssertTrue(first.displayLabel.hasPrefix("Name with breaks and spaces"))
    }

    func testEmptyNamesFallBackToAGenericLabel() {
        let built = ExtensionSnapshotBuilder.make(
            gateways: [.init(handle: handle(1), displayName: " \n ", runningCount: 0, needsAttentionCount: 0, onlineCount: 0)],
            appLockEnabled: false, now: now)
        XCTAssertEqual(built.gateways[0].displayLabel, "Gateway 1")
    }

    // MARK: opaque handle

    func testGeneratedHandlesAreOpaqueAndValid() throws {
        let a = try XCTUnwrap(OpaqueGatewayHandle.generate())
        let b = try XCTUnwrap(OpaqueGatewayHandle.generate())
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a.count, 22)
        XCTAssertTrue(OpaqueGatewayHandle.isValid(a))
        XCTAssertFalse(OpaqueGatewayHandle.isValid("gateway.example.test"))
    }

    // MARK: file protection

    func testFileProtectionClassIsCompleteUntilFirstUserAuthentication() throws {
        XCTAssertEqual(ExtensionSnapshotStore.fileProtection, .completeUntilFirstUserAuthentication)
        try store.write(snapshot())
        #if os(iOS)
        let attributes = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
        XCTAssertEqual(attributes[.protectionKey] as? FileProtectionType,
                       .completeUntilFirstUserAuthentication)
        #endif
    }

    func testContainerBackedStoreExcludesTheDirectoryFromBackup() throws {
        let container = FleetSharedContainer(
            backing: .appContainerFallback,
            directoryURL: directory.appendingPathComponent(FleetSharedContainer.directoryName, isDirectory: true))
        let store = ExtensionSnapshotStore(container: container)
        try store.write(snapshot())
        XCTAssertEqual(store.fileURL.lastPathComponent, FleetSharedContainer.Location.extensionSnapshot.rawValue)
        let values = try container.directoryURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
        XCTAssertEqual(try store.read(), snapshot())
    }
}
