package tests

import b "../build_odin"
import "core:log"
import "core:time"
import "utils"

cmd_async_start :: proc() -> (ok: bool) {
    before := time.now()
    processes: [10]b.Process
    sh := b.program("sh")
    for &process in processes {
        process = b.run_prog_async(sh, {"-c", "echo 'HELLO, WORLD!'"}, .Capture) or_return
    }
    results := b.process_wait_many(processes[:], context.temp_allocator) or_return
    for result in results {
        utils.expect("HELLO, WORLD!\n", result.stdout) or_return
    }
    log.infof("Time elapsed: %v", time.since(before))
    return true
}

main :: proc() {
    b.start(cmd_async_start)
}

