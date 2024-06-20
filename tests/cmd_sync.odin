package tests

import src ".."
import "core:log"
import "core:time"

cmd_sync_start :: proc() -> (ok: bool) {
    before := time.now()
    results: [10]src.Process_Result
    for &result in results {
        result = src.run_cmd_sync({"sh", "-c", "echo 'HELLO, WORLD!'"}, .Silent) or_return
    }
    _ = results
    log.infof("Time elapsed: %v", time.since(before))
    return true
}

main :: proc() {
    src._entry(cmd_sync_start)
}

