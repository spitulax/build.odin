package build

import build "build_odin"
import "core:log"

start :: proc() -> (ok: bool) {
    log.info("Hello, World!")
    return true
}

main :: proc() {
    build.run(start)
}

