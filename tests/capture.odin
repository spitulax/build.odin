package tests

import build "../build.odin"
import "core:log"

capture_start :: proc() -> (ok: bool) {
    result1 := build.run_cmd_sync(
        {"sh", "-c", "echo 'HELLO, STDOUT!' > /dev/stdout"},
        .Capture,
    ) or_return
    defer build.process_result_destroy(&result1)
    if !(result1.stdout == "HELLO, STDOUT!\n" && result1.stderr == "") {
        log.errorf("Unexpected output:\n%#v", result1)
        return false
    }

    result2 := build.run_cmd_sync(
        {"sh", "-c", "echo 'HELLO, STDERR!' > /dev/stderr"},
        .Capture,
    ) or_return
    defer build.process_result_destroy(&result2)
    if !(result2.stderr == "HELLO, STDERR!\n" && result2.stdout == "") {
        log.errorf("Unexpected output:\n%#v", result2)
        return false
    }

    result3 := build.run_cmd_sync(
        {"sh", "-c", "echo 'HELLO, STDOUT!' > /dev/stdout; echo 'HELLO, STDERR!' > /dev/stderr"},
        .Capture,
    ) or_return
    defer build.process_result_destroy(&result3)
    if !(result3.stderr == "HELLO, STDERR!\n" && result3.stdout == "HELLO, STDOUT!\n") {
        log.errorf("Unexpected output:\n%#v", result3)
        return false
    }

    return true
}

main :: proc() {
    build.run(capture_start)
}

