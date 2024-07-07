package test_utils

import "core:log"
import "core:strconv"

expect :: proc {
    expect_string,
}

@(require_results)
expect_string :: proc(expected: string, actual: string, location := #caller_location) -> bool {
    if expected != actual {
        expected_buf := make([]byte, len(expected) * size_of(rune), context.temp_allocator)
        expected_quoted := strconv.quote(expected_buf, expected)
        actual_buf := make([]byte, len(actual) * size_of(rune), context.temp_allocator)
        actual_quoted := strconv.quote(actual_buf, actual)
        log.errorf("Expected %s, got %s", expected_quoted, actual_quoted, location = location)
        return false
    }
    return true
}

