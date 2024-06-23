package build

import "core:fmt"

start :: proc() -> (ok: bool) {
    result := run_cmd_sync({"nvim"}, .Capture) or_return
    defer process_result_destroy(&result)
    if result.exit == nil {
        fmt.println("took:", result.duration)
        fmt.println(result.stdout)
    } else {
        fmt.println("exited:", result.exit)
        fmt.println(result.stderr)
    }
    return true
}

main :: proc() {
    run(start)
}

