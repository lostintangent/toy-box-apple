import ToyBoxClient
import ToyBoxKit
import Testing

@MainActor
struct RoutineScheduleSummaryTests {
    @Test func routineSchedulesUseReadableSummariesAndKeepUnknownSyntax() throws {
        let weekdays = try RoutineSchedule("0 9 * * 1-5").summary()
        #expect(RoutineScheduleSummary.text(for: "0 9 * * 1-5") == weekdays)
        #expect(RoutineScheduleSummary.text(for: "H 9 * * *") == "H 9 * * *")
        #expect(RoutineScheduleSummary.text(for: "not a schedule") == "not a schedule")
    }
}
