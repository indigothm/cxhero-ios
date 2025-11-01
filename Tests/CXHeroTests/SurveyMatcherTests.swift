import Foundation
import Testing
@testable import CXHero

@Test("PropertyMatcher numeric comparisons and contains")
func propertyMatcherBasics() async throws {
    #expect(PropertyMatcher.greaterThan(10).matches(.int(11)) == true)
    #expect(PropertyMatcher.lessThanOrEqual(10).matches(.double(10.0)) == true)
    #expect(PropertyMatcher.contains("foo").matches(.string("foobar")) == true)
    #expect(PropertyMatcher.notContains("foo").matches(.string("bar")) == true)
    #expect(PropertyMatcher.equals(.int(3)).matches(.double(3.0)) == true)
    #expect(PropertyMatcher.notEquals(.bool(true)).matches(.bool(false)) == true)
}

