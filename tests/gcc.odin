package tests

import build "../build_odin"
import "core:log"
import "core:strconv"

gcc_start :: proc() -> (ok: bool) {
    result := build.run_cmd_sync(
        {"cc", "-o", "./rats/gcc/main", "./rats/gcc/main.c"},
        .Capture,
    ) or_return
    defer build.process_result_destroy(&result)
    if result.exit != nil {
        log.errorf("gcc exited with %v: %s", result.exit, result.stderr)
        return false
    }
    // TODO: specify environment variable
    // eg. adding ./rats/gcc/main to PATH for this operation to call it without sh
    result2 := build.run_cmd_sync({"sh", "-c", "./rats/gcc/main"}, .Capture) or_return
    defer build.process_result_destroy(&result2)
    if result2.exit != nil {
        log.errorf("sh exited with %v: %s", result2.exit, result2.stderr)
        return false
    }
    expected :: "Hello, World!\n"
    if result2.stdout != expected {
        expected_buf := make([]byte, len(expected) * size_of(rune), context.temp_allocator)
        expected_quoted := strconv.quote(expected_buf, expected)
        actual_buf := make([]byte, len(result2.stdout) * size_of(rune), context.temp_allocator)
        actual_quoted := strconv.quote(actual_buf, result2.stdout)
        log.errorf("expected %s, got %s", expected_quoted, actual_quoted)
        return false
    }
    return true
}

main :: proc() {
    build.run(gcc_start)
}

