package tests

import b "../build_odin"

stdin_start :: proc() -> (ok: bool) {
    sh := b.program("sh")
    // TODO: redirect something into stdin
    b.run_prog_sync(sh, {"-c", "./rats/stdin"}, .Silent, context.temp_allocator) or_return
    b.run_prog_sync(
        sh,
        {"-c", "read TEST && echo $TEST"},
        .Capture,
        context.temp_allocator,
    ) or_return
    return true
}

main :: proc() {
    b.run(stdin_start)
}

