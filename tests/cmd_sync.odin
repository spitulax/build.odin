package tests

import b "../build_odin"
import "core:log"
import "core:time"
import "utils"

cmd_sync_start :: proc() -> (ok: bool) {
    before := time.now()
    results: [10]b.Process_Result
    defer b.process_result_destroy_many(results[:])
    sh := b.program("sh")
    for &result in results {
        result = b.run_cmd_sync(sh, {"-c", "echo 'HELLO, WORLD!'"}, .Capture) or_return
        utils.expect("HELLO, WORLD!\n", result.stdout) or_return
    }
    log.infof("Time elapsed: %v", time.since(before))
    return true
}

main :: proc() {
    b.run(cmd_sync_start)
}

