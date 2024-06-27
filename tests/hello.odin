package tests

import build "../build_odin"

simple_start :: proc() -> (ok: bool) {
    result := build.run_cmd_sync({"sh", "-c", "echo 'Hello, World!'"}, .Share) or_return
    assert(len(result.stdout) == 0 && len(result.stderr) == 0)
    defer build.process_result_destroy(&result)
    return true
}

main :: proc() {
    build.run(simple_start)
}

