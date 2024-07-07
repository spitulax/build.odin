package tests

import build "../build_odin"
import "utils"

simple_start :: proc() -> (ok: bool) {
    result := build.run_cmd_sync({"sh", "-c", "echo 'Hello, World!'"}, .Share) or_return
    assert(result.exit == nil && len(result.stdout) == 0 && len(result.stderr) == 0)
    build.process_result_destroy(&result)

    result = build.run_cmd_sync({"sh", "-c", "echo 'Hello, World!'"}, .Capture) or_return
    assert(result.exit == nil && len(result.stderr) == 0)
    utils.expect("Hello, World!\n", result.stdout) or_return
    build.process_result_destroy(&result)

    result = build.run_cmd_sync({"sh", "-c", "echo 'Hello, World!'"}, .Silent) or_return
    assert(result.exit == nil && len(result.stdout) == 0 && len(result.stderr) == 0)
    build.process_result_destroy(&result)

    return true
}

main :: proc() {
    build.run(simple_start)
}

