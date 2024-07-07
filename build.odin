package build

import b "build_odin"
import "core:log"

start :: proc() -> (ok: bool) {
    log.info("Hello, World!")
    return true
}

main :: proc() {
    b.run(start)
}

