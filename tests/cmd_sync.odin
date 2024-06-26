package tests

import "../build_odin/lib"
import "core:log"
import "core:time"

cmd_sync_start :: proc() -> (ok: bool) {
    before := time.now()
    results: [10]lib.Process_Result
    defer lib.process_result_destroy_many(results[:])
    for &result in results {
        result = lib.run_cmd_sync({"sh", "-c", "echo 'HELLO, WORLD!'"}, .Silent) or_return
    }
    log.infof("Time elapsed: %v", time.since(before))
    return true
}

main :: proc() {
    lib.run(cmd_sync_start)
}

