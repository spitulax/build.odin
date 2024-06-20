package tests

import build "../build.odin"
import "core:log"
import "core:time"

cmd_async_start :: proc() -> (ok: bool) {
    before := time.now()
    processes: [10]build.Process
    for &process in processes {
        process = build.run_cmd_async({"sh", "-c", "echo 'HELLO, WORLD!'"}, .Silent) or_return
    }
    results := build.process_wait_many(processes[:], context.temp_allocator) or_return
    defer build.process_result_destroy_many(results[:])
    log.infof("Time elapsed: %v", time.since(before))
    return true
}

main :: proc() {
    build.run(cmd_async_start)
}

