package build

start :: proc() -> (ok: bool) {
    return true
}

main :: proc() {
    run(start)
}

