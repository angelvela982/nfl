import Foundation
import XCTest
@testable import NFLPulseCore

final class CompatibilityTests: XCTestCase {
    func testOriginalSnapshotLoadsWithoutNewMetricZeros() throws {
        let legacy = #"{"fetchedAt":0,"season":2025,"players":[{"id":"p","name":"Beta original","team":"CHI","position":"RB","status":"ACT"}],"games":[],"stats":[{"playerID":"p","gameID":"g","season":2025,"week":1,"team":"CHI","opponent":"GB","position":"RB","passing":0,"rushing":40,"receiving":0,"receptions":0,"attempts":0,"carries":10,"targets":0}],"injuries":[],"sources":[],"warnings":[]}"#
        let recovered = try JSONDecoder().decode(Snapshot.self, from: Data(legacy.utf8))
        XCTAssertNil(recovered.players[0].espnID)
        XCTAssertNil(recovered.stats[0].observed(.fieldGoals))
        XCTAssertNil(recovered.stats[0].observed(.completions))
        XCTAssertEqual(recovered.stats[0].observed(.receptions), 0)
        XCTAssertEqual(recovered.stats[0].observed(.carries), 10)
    }

    func testOriginalHistoryKeepsFirstPredictionAndUnknownContext() throws {
        let legacy = #"[{"projection":{"id":"F72BF696-88E5-48B1-83CA-FDB10047C0E1","createdAt":0,"player":{"id":"p","name":"Beta original","team":"CHI","position":"RB","status":"ACT"},"game":{"id":"g","season":2025,"week":1,"kind":"REG","kickoff":1000,"home":"CHI","away":"GB","stadium":"Test","roof":"outdoors","location":"Home","completed":false},"metric":"rushing_yards","estimate":42.5,"sample":4,"defenseFactor":1,"recent":[20,40,60,50],"warnings":[],"model":"Base 0.1","dataAsOf":0},"actual":40,"settlement":"Resultado registrado"}]"#
        let recovered = try JSONDecoder().decode([SavedProjection].self, from: Data(legacy.utf8))
        XCTAssertEqual(recovered[0].projection.estimate, 42.5)
        XCTAssertEqual(recovered[0].actual, 40)
        XCTAssertNil(recovered[0].projection.context)
        XCTAssertNil(recovered[0].corrections)
        let roundTrip = try JSONDecoder().decode([SavedProjection].self, from: JSONEncoder().encode(recovered))
        XCTAssertEqual(roundTrip[0].id, recovered[0].id)
    }

    func testPythonServiceFixtureUsesExactlyTheSwiftContextContract() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("server/fixtures/live-context.json"))
        let context = try LiveContextService.decodeContext(data)
        XCTAssertFalse(context.sources.isEmpty)
        XCTAssertFalse(context.news.isEmpty)
        let report = try XCTUnwrap(context.reports.first { $0.status == .out })
        XCTAssertEqual(report.playerID, "00-0039849")
        XCTAssertEqual(report.espnID, "4432708")
        XCTAssertNotNil(report.gameID)
        XCTAssertTrue(report.sourceURL.hasPrefix("https://"))
        XCTAssertNotNil(report.reportedAt)
    }
}
