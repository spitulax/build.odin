package tests

import b ".."
import "core:log"
import "utils"

build_stage_proc :: proc(self: ^b.Stage, userdata: rawptr) -> (ok: bool) {
    cc := b.program("cc")
    sh := b.program("sh")

    result := b.run_prog_sync(
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
    result2 := b.run_prog_sync(sh, {"-c", "./rats/gcc/main"}, .Capture) or_return
    defer b.process_result_destroy(&result2)
    if result2.exit != nil {
        log.errorf("sh exited with %v: %s", result2.exit, result2.stderr)
        return false
    }

    utils.expect(result2.stdout, "Hello, World!\n") or_return

    return true
}

gcc_start :: proc() -> (ok: bool) {
    build_stage := b.stage_make(build_stage_proc, "build")
    defer b.destroy_stages(&build_stage)

    b.run_stages(&build_stage) or_return
    return true
}

main :: proc() {
    b.start(gcc_start)
}

