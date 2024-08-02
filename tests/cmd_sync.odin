package tests

import b ".."
import "core:log"
import "core:time"
import "utils"

cmd_sync_start :: proc() -> (ok: bool) {
    before := time.now()
    results: [10]b.Process_Result
    defer b.process_result_destroy_many(results[:])
    sh := b.program("sh")
    for &result in results {
        result = b.run_prog_sync(sh, {"-c", "echo 'HELLO, WORLD!'"}, .Capture) or_return
        utils.expect(result.stdout, "HELLO, WORLD!\n") or_return
    }
    log.infof("Time elapsed: %v", time.since(before))
    return true
}

main :: proc() {
    b.start(cmd_sync_start)
}

