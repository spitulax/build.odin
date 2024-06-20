package tests

import build "../build.odin"
import "core:log"
import "core:time"

cmd_sync_start :: proc() -> (ok: bool) {
    before := time.now()
    results: [10]build.Process_Result
    defer build.process_result_destroy_many(results[:])
    for &result in results {
        result = build.run_cmd_sync({"sh", "-c", "echo 'HELLO, WORLD!'"}, .Silent) or_return
    }
    log.infof("Time elapsed: %v", time.since(before))
    return true
}

main :: proc() {
    build.run(cmd_sync_start)
}

