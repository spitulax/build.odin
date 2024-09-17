package tests

import b ".."
import "core:log"

filepath_start :: proc() -> (ok: bool) {
    path := b.path("../build.odin") or_return
    stat := b.file_stat(path, {}) or_return
    log.info(path)
    log.info(stat)

    return true
}

main :: proc() {
    b.start(filepath_start)
}

