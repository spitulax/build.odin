package tests

import "../build_odin/lib"

stdin_start :: proc() -> (ok: bool) {
    // TODO: redirect something into stdin
    lib.run_cmd_sync({"sh", "-c", "./rats/stdin"}, .Silent, context.temp_allocator) or_return
    lib.run_cmd_sync(
        {"sh", "-c", "read TEST && echo $TEST"},
        .Capture,
        context.temp_allocator,
    ) or_return
    return true
}

main :: proc() {
    lib.run(stdin_start)
}

