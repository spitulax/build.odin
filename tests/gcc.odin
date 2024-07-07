package tests

import b "../build_odin"
import "core:log"
import "utils"

gcc_start :: proc() -> (ok: bool) {
    cc := b.program("cc")
    sh := b.program("sh")

    result := b.run_cmd_sync(
        cc,
        {"-o", "./rats/gcc/main", "./rats/gcc/main.c"},
        .Capture,
    ) or_return
    defer b.process_result_destroy(&result)
    if result.exit != nil {
        log.errorf("gcc exited with %v: %s", result.exit, result.stderr)
        return false
    }
    // TODO: specify environment variable
    // eg. adding ./rats/gcc/main to PATH for this operation to call it without sh
    result2 := b.run_cmd_sync(sh, {"-c", "./rats/gcc/main"}, .Capture) or_return
    defer b.process_result_destroy(&result2)
    if result2.exit != nil {
        log.errorf("sh exited with %v: %s", result2.exit, result2.stderr)
        return false
    }

    utils.expect("Hello, World!\n", result2.stdout) or_return

    return true
}

main :: proc() {
    b.run(gcc_start)
}

