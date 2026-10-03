This fixture was exported from a real macOS XCTest result produced by Xcode 27.0 with `-retry-tests-on-failure -test-iterations 2`. A synthetic test fails its first attempt and passes its retry. Xcode represents both attempts as `Repetition` children of one passed `Test Case`.

Device metadata, timestamps, durations and source locations were removed. Test names and project names are synthetic. The result/type hierarchy is retained from `xcresulttool get test-results tests`; this fixture proves the nested retry layout, not iOS UI behavior or CI environment equivalence.
