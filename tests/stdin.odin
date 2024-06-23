package tests

import build "../build_odin"

stdin_start :: proc() -> (ok: bool) {
    // TODO: redirect something into stdin
    build.run_cmd_sync({"sh", "-c", "./rats/stdin"}, .Silent, context.temp_allocator) or_return
    build.run_cmd_sync(
        {"sh", "-c", "read TEST && echo $TEST"},
        .Capture,
        context.temp_allocator,
    ) or_return
    return true
}

main :: proc() {
    build.run(stdin_start)
}

