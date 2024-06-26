package tests

import "../build_odin/lib"
import "core:log"
import "core:time"

cmd_async_start :: proc() -> (ok: bool) {
    before := time.now()
    processes: [10]lib.Process
    for &process in processes {
        process = lib.run_cmd_async({"sh", "-c", "echo 'HELLO, WORLD!'"}, .Silent) or_return
    }
    results := lib.process_wait_many(processes[:], context.temp_allocator) or_return
    defer lib.process_result_destroy_many(results[:])
    log.infof("Time elapsed: %v", time.since(before))
    return true
}

main :: proc() {
    lib.run(cmd_async_start)
}

