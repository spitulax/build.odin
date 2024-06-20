package tests

import src ".."
import "core:log"

capture_start :: proc() -> (ok: bool) {
    result1 := src.run_cmd_sync(
        {"sh", "-c", "echo 'HELLO, STDOUT!' > /dev/stdout"},
        .Capture,
    ) or_return
    defer src.process_result_destroy(&result1)
    if !(result1.stdout == "HELLO, STDOUT!\n" && result1.stderr == "") {
        log.errorf("Unexpected output:\n%#v", result1)
        return false
    }

    result2 := src.run_cmd_sync(
        {"sh", "-c", "echo 'HELLO, STDERR!' > /dev/stderr"},
        .Capture,
    ) or_return
    defer src.process_result_destroy(&result2)
    if !(result2.stderr == "HELLO, STDERR!\n" && result2.stdout == "") {
        log.errorf("Unexpected output:\n%#v", result2)
        return false
    }

    result3 := src.run_cmd_sync(
        {"sh", "-c", "echo 'HELLO, STDOUT!' > /dev/stdout; echo 'HELLO, STDERR!' > /dev/stderr"},
        .Capture,
    ) or_return
    defer src.process_result_destroy(&result3)
    if !(result3.stderr == "HELLO, STDERR!\n" && result3.stdout == "HELLO, STDOUT!\n") {
        log.errorf("Unexpected output:\n%#v", result3)
        return false
    }

    return true
}

main :: proc() {
    src._entry(capture_start)
}

