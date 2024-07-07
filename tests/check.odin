package tests

import b "../build_odin"

main :: proc() {
    b.run(proc() -> (ok: bool) {
        res := b.run_cmd_sync(
            b.program("notarealcommand"),
            {"--help"},
            allocator = context.temp_allocator,
            require = false,
        ) or_return
        return res == {}
    })
}

