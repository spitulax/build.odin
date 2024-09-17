package tests

import b ".."
import "core:log"

filepath_start :: proc() -> (ok: bool) {
    path := b.path("../build.odin") or_return
    stat := b.file_stat(path, {}) or_return
    log.info(path)
    log.info(stat)

    paths := []string{"rats/gcc/main.c", "rats/stdin"}
    realpaths := b.verify_paths(paths[:]) or_return
    defer delete(realpaths)
    log.info(realpaths)

    return true
}

main :: proc() {
    b.start(filepath_start)
}

