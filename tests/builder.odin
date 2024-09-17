package tests

import b ".."
import "core:log"

root_proc :: proc(self: ^b.Builder, stage: ^b.Stage) -> (ok: bool) {
    log.debugf("%#v", self^)
    log.debugf("%#v", stage^)

    return true
}

builder_start :: proc() -> (ok: bool) {
    builder := b.Builder {
        name      = "root",
        procedure = root_proc,
        source    = {"rats/gcc/main.c"},
    }
    root := b.builder_stage(&builder)

    b.run_stages(&root) or_return

    return true
}

main :: proc() {
    b.start(builder_start)
}

