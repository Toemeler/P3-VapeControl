import XCTest

/// The Lock Screen card's arithmetic. It is worth testing precisely because it
/// is invisible: a ring that reads wrong on a locked phone is not something
/// anyone notices as a bug, they just stop trusting the card.
final class PaxActivityStateTests: XCTestCase {

    private func state(phase: PaxActivityAttributes.ContentState.Phase,
                       actual: Double? = nil,
                       target: Double? = nil,
                       battery: Int? = nil) -> PaxActivityAttributes.ContentState {
        PaxActivityAttributes.ContentState(
            phase: phase,
            lastSeen: nil,
            isConnected: phase != .waiting,
            headline: "test",
            batteryLevel: battery,
            isCharging: phase == .charging,
            actualTempC: actual,
            targetTempC: target,
            ledColorHex: "#FF6A00",
            useFahrenheit: false)
    }

    // MARK: - The ring

    func testChargingRingIsTheBatteryLevel() {
        XCTAssertEqual(state(phase: .charging, battery: 0).ringFraction, 0, accuracy: 0.0001)
        XCTAssertEqual(state(phase: .charging, battery: 50).ringFraction, 0.5, accuracy: 0.0001)
        XCTAssertEqual(state(phase: .charging, battery: 100).ringFraction, 1, accuracy: 0.0001)
    }

    /// Below the dial's floor there is no reading to place on the scale, but a
    /// ring at zero would claim nothing is happening while the oven climbs.
    func testColdClimbGetsTheFirstSliverOfTheRing() {
        let roomTemperature = state(phase: .heating, actual: 30, target: 215)
        XCTAssertEqual(roomTemperature.ringFraction, 0, accuracy: 0.0001)

        let halfwayUp = state(phase: .heating, actual: 105, target: 215)  // 30 → 180
        XCTAssertEqual(halfwayUp.ringFraction, 0.04, accuracy: 0.005)

        let atTheFloor = state(phase: .heating, actual: 180, target: 215)
        XCTAssertEqual(atTheFloor.ringFraction, 0.08, accuracy: 0.0001)
    }

    /// The seam at 180 °C is the one place this could visibly go wrong: the arc
    /// must not jump backwards as the reading crosses onto the dial's scale.
    func testTheRingDoesNotJumpBackwardsAtTheDialFloor() {
        let below = state(phase: .heating, actual: 179.9, target: 215).ringFraction
        let above = state(phase: .heating, actual: 180.1, target: 215).ringFraction
        XCTAssertLessThan(below, above)
        XCTAssertEqual(above - below, 0, accuracy: 0.01, "the two sides should meet, not step")
    }

    func testTopOfTheDialFillsTheRing() {
        XCTAssertEqual(state(phase: .ready, actual: 225, target: 225).ringFraction, 1, accuracy: 0.0001)
        XCTAssertEqual(state(phase: .ready, actual: 400, target: 225).ringFraction, 1, accuracy: 0.0001,
                       "a reading past the top is still a full ring, never more")
    }

    func testRingIsEmptyWithoutAReading() {
        XCTAssertEqual(state(phase: .ready).ringFraction, 0, accuracy: 0.0001)
    }

    // MARK: - The warm-up colour

    func testWarmUpFractionSpansRoomTemperatureToTheSetPoint() {
        XCTAssertEqual(state(phase: .heating, actual: 30, target: 230).warmUpFraction, 0, accuracy: 0.0001)
        XCTAssertEqual(state(phase: .heating, actual: 130, target: 230).warmUpFraction, 0.5, accuracy: 0.0001)
        XCTAssertEqual(state(phase: .heating, actual: 230, target: 230).warmUpFraction, 1, accuracy: 0.0001)
    }

    func testWarmUpFractionIsClamped() {
        XCTAssertEqual(state(phase: .heating, actual: 10, target: 215).warmUpFraction, 0, accuracy: 0.0001)
        XCTAssertEqual(state(phase: .heating, actual: 300, target: 215).warmUpFraction, 1, accuracy: 0.0001)
    }

    /// No target means no ramp to draw, and the colour should land on the end
    /// of the gradient rather than on "stone cold".
    func testWarmUpFractionWithoutATarget() {
        XCTAssertEqual(state(phase: .heating, actual: 100).warmUpFraction, 1, accuracy: 0.0001)
    }

    // MARK: - Which number leads

    func testTheLeadNumberIsWhateverTheStateIsAbout() {
        XCTAssertEqual(state(phase: .charging, battery: 82).leadNumber, "82%")
        XCTAssertEqual(state(phase: .heating, actual: 173).leadNumber, "173°C")
        XCTAssertEqual(state(phase: .waiting).leadNumber, "--")
    }

    func testFahrenheitFormatting() {
        var f = state(phase: .ready, actual: 100)
        f.useFahrenheit = true
        XCTAssertEqual(f.leadNumber, "212°F")
    }

    func testOvenActivePhases() {
        for phase in [PaxActivityAttributes.ContentState.Phase.heating, .ready, .drawing, .cooling] {
            XCTAssertTrue(state(phase: phase).isOvenActive, "\(phase)")
        }
        for phase in [PaxActivityAttributes.ContentState.Phase.waiting, .charging, .standby, .ovenOff] {
            XCTAssertFalse(state(phase: phase).isOvenActive, "\(phase)")
        }
    }

    /// The card only updates when the state changes, so equality is what keeps
    /// the app inside the system's Live Activity update budget.
    func testEqualStatesAreEqual() {
        XCTAssertEqual(state(phase: .heating, actual: 173, target: 215, battery: 95),
                       state(phase: .heating, actual: 173, target: 215, battery: 95))
        XCTAssertNotEqual(state(phase: .heating, actual: 173, target: 215, battery: 95),
                          state(phase: .heating, actual: 174, target: 215, battery: 95))
    }
}
