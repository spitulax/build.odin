package build

start :: proc() -> (ok: bool) {
    return true
}

main :: proc() {
    _entry(start)
}

