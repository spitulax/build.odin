package tests

import b ".."

main :: proc() {
    b.start(proc() -> (ok: bool) {
        res := b.run_prog_sync(
            b.program("notarealcommand"),
            {"--help"},
            allocator = context.temp_allocator,
            require = false,
        ) or_return
        return res == {}
    })
}

