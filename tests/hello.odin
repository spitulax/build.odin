package tests

import b ".."
import "utils"

hello_start :: proc() -> (ok: bool) {
    sh := b.program("sh")

    result := b.run_prog_sync(sh, {"-c", "echo 'Hello, World!'"}, .Share) or_return
    assert(result.exit == nil && len(result.stdout) == 0 && len(result.stderr) == 0)
    b.process_result_destroy(&result)

    result = b.run_prog_sync(sh, {"-c", "echo 'Hello, World!'"}, .Capture) or_return
    assert(result.exit == nil && len(result.stderr) == 0)
    utils.expect("Hello, World!\n", result.stdout) or_return
    b.process_result_destroy(&result)

    result = b.run_prog_sync(sh, {"-c", "echo 'Hello, World!'"}, .Silent) or_return
    assert(result.exit == nil && len(result.stdout) == 0 && len(result.stderr) == 0)
    b.process_result_destroy(&result)

    return true
}

main :: proc() {
    b.start(hello_start)
}

