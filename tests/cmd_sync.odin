package tests

import src ".."
import "core:log"
import "core:time"

cmd_sync_start :: proc() -> (ok: bool) {
    before := time.now()
    results: [10]src.Process_Result
    defer src.process_result_destroy_many(results[:])
    for &result in results {
        result = src.run_cmd_sync({"sh", "-c", "echo 'HELLO, WORLD!'"}, .Silent) or_return
    }
    log.infof("Time elapsed: %v", time.since(before))
    return true
}

main :: proc() {
    src.run(cmd_sync_start)
}

