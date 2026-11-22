import XCTest
@testable import LittleBearTutor

final class ParentLockTests: XCTestCase {
    private let base = LockStatus(deviceId: "d", name: "林林的平板", enabled: true, lockedApps: 3, stalled: false, adminActive: true,
                                  reportedAt: "2026-11-22T07:39:00.000Z", problem: nil)

    func testMessagesMatchTheAndroidParentApp() {
        XCTAssertEqual(lockMessage(base, zone: "Asia/Shanghai"), "林林的平板：锁定正常，锁住 3 个 App，11/22 15:39 报告")
        var lock = base; lock.adminActive = false
        XCTAssertTrue(lockMessage(lock, zone: "Asia/Shanghai").hasSuffix("没开“防止卸载”"))
        lock = base; lock.problem = "off"
        XCTAssertTrue(lockMessage(lock, zone: "Asia/Shanghai").contains("重新开启"))
        lock.problem = "paused"
        XCTAssertTrue(lockMessage(lock, zone: "Asia/Shanghai").contains("无限制"))
        lock.problem = "silent"
        XCTAssertTrue(lockMessage(lock, zone: "Asia/Shanghai").contains("最后一次 11/22 15:39"))
        lock = base; lock.name = ""
        XCTAssertTrue(lockMessage(lock, zone: "Asia/Shanghai").hasPrefix("孩子的平板"))
        XCTAssertEqual(lockTime("2026-11-22T07:39:00Z", zone: "Asia/Shanghai"), "11/22 15:39")
        XCTAssertEqual(lockTime("not a time", zone: "Asia/Shanghai"), "")
    }

    /// A server deployed before the heartbeat sends no `locks`; the app must still read `/v1/me`.
    func testMeFromAnOlderServerStillDecodes() throws {
        let me = """
        {"cursor": 3, "device": {"id": "\(UUID())", "role": "parent", "name": "iPhone"},
         "family": {"id": "\(UUID())", "name": "", "timezone": "Asia/Shanghai", "today": "2026-11-22"},
         "children": [], "rules": \(String(data: try JSONEncoder().encode(RewardRules()), encoding: .utf8)!)}
        """
        XCTAssertNil(try JSONDecoder().decode(MeResponse.self, from: Data(me.utf8)).locks)
    }
}
