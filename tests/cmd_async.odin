package tests

import build "../build_odin"
import "core:log"
import "core:time"
import "utils"

cmd_async_start :: proc() -> (ok: bool) {
    before := time.now()
    processes: [10]build.Process
    for &process in processes {
        process = build.run_cmd_async({"sh", "-c", "echo 'HELLO, WORLD!'"}, .Capture) or_return
    }
    results := build.process_wait_many(processes[:], context.temp_allocator) or_return
    for result in results {
        utils.expect("HELLO, WORLD!\n", result.stdout) or_return
    }
    log.infof("Time elapsed: %v", time.since(before))
    return true
}

main :: proc() {
    build.run(cmd_async_start)
}

