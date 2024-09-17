package tests

import b ".."
import "core:log"
import "utils"

filepath_start :: proc() -> (ok: bool) {
    path := b.path("../build.odin") or_return
    stat := b.file_stat(path, {}) or_return
    log.info(path)
    log.info(stat)

    paths := []b.Filepath{"rats/gcc/main.c", "rats/stdin"}
    b.verify_paths(paths[:]) or_return
    log.info(paths)

    utils.expect(b.is_path_absolute("../build.odin"), false) or_return
    utils.expect(b.is_path_absolute(path), true) or_return

    return true
}

main :: proc() {
    b.start(filepath_start)
}

