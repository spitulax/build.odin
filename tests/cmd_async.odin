package tests

import src ".."
import "core:log"
import "core:time"

cmd_async_start :: proc() -> (ok: bool) {
    before := time.now()
    processes: [10]src.Process
    for &process in processes {
        process = src.run_cmd_async({"sh", "-c", "echo 'HELLO, WORLD!'"}, .Silent) or_return
    }
    results := src.process_wait_many(processes[:], context.temp_allocator) or_return
    defer src.process_result_destroy_many(results[:])
    log.infof("Time elapsed: %v", time.since(before))
    return true
}

main :: proc() {
    src.run(cmd_async_start)
}

