import Foundation

/// Simple error type for test assertions
struct TestError: Error, CustomStringConvertible {
    let message: String
    
    init(_ message: String) {
        self.message = message
    }
    
    var description: String {
        "TestError: \(message)"
    }
}




