package test_utils

import "base:intrinsics"
import "core:log"
import "core:mem"
import "core:strconv"

_ :: mem

expect :: proc {
    expect_slice,
    expect_string,
    expect_any,
}

@(require_results)
expect_any :: proc(
    actual: $T,
    expected: T,
    location := #caller_location,
) -> bool where intrinsics.type_is_comparable(T) {
    if expected != actual {
        log.errorf("Expected `%v`, got `%v`", expected, actual, location = location)
        return false
    }
    return true
}

@(require_results)
expect_string :: proc(actual: string, expected: string, location := #caller_location) -> bool {
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

@(require_results)
expect_slice :: proc(actual: $T/[]$E, expected: T, location := #caller_location) -> bool {
    if len(expected) != len(actual) {
        log.errorf(
            "Expected length is %v, actual length is %v",
            len(expected),
            len(actual),
            location = location,
        )
        return false
    }
    diffs := make([dynamic]int, 0, len(expected))
    defer delete(diffs)
    for x, i in actual {
        if x != expected[i] {
            append(&diffs, i)
        }
    }
    if len(diffs) > 0 {
        for diff in diffs {
            log.errorf(
                "At index %v: Expected `%v`, got `%v`",
                diff,
                expected[diff],
                actual[diff],
                location = location,
            )
        }
        return false
    }
    return true
}

