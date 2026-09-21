import Foundation

// Shared by both harness targets (see run-tests.sh), so an assertion means the
// same thing in each and neither can drift from the other.

var failures = 0

func check(_ condition: Bool, _ label: String) {
    if condition {
        print("  ok   \(label)")
    } else {
        print("  FAIL \(label)")
        failures += 1
    }
}

func checkEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
    if actual == expected {
        print("  ok   \(label)")
    } else {
        print("  FAIL \(label): got \(actual), expected \(expected)")
        failures += 1
    }
}
