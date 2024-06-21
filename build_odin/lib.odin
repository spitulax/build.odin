package build

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"

OS_Set :: bit_set[runtime.Odin_OS_Type]
SUPPORTED_OS :: OS_Set{.Linux}
#assert(ODIN_OS in SUPPORTED_OS)

run :: proc(start_func: proc() -> bool) {
    prog_flags: Prog_Flags
    if !parse_args(&prog_flags) {
        usage()
        os.exit(1)
    }

    mem_track: mem.Tracking_Allocator
    context_allocator := context.allocator
    if prog_flags.track_alloc {
        mem.tracking_allocator_init(&mem_track, context_allocator)
        context_allocator = mem.tracking_allocator(&mem_track)
    }
    context.allocator = context_allocator

    context.logger = log.create_console_logger()

    ok := start_func()

    free_all(context.temp_allocator)
    log.destroy_console_logger(context.logger)
    if prog_flags.track_alloc {
        fmt.eprint("\033[1;31m")
        if len(mem_track.allocation_map) > 0 {
            fmt.eprintfln("### %v unfreed allocations ###", len(mem_track.allocation_map))
            for _, v in mem_track.allocation_map {
                fmt.eprintfln("    %v bytes in %v", v.size, v.location)
            }
        }
        if len(mem_track.bad_free_array) > 0 {
            fmt.eprintfln("### %v bad frees ###", len(mem_track.bad_free_array))
            for x in mem_track.bad_free_array {
                fmt.eprintfln("    %p in %v", x.memory, x.location)
            }
        }
        fmt.eprint("\033[0m")
        mem.tracking_allocator_destroy(&mem_track)
    }
    os.exit(!ok)
}

@(private = "file")
usage :: proc() {
    fmt.println("./build [options]...")
    fmt.println()
    fmt.println("Options:")
    fmt.println("    --track-alloc      Track for unfreed and double freed memory")
}

@(private = "file")
Prog_Flags :: struct {
    track_alloc: bool,
}

@(private = "file", require_results)
parse_args :: proc(prog_flags: ^Prog_Flags) -> (ok: bool) {
    @(require_results)
    next_arg :: proc(args: ^[]string) -> (arg: string, ok: bool) {
        if len(args) <= 0 {
            return
        }
        arg = args^[0]
        args^ = args^[1:]
        return arg, true
    }

    args := os.args
    _ = next_arg(&args) or_return

    for {
        arg, arg_ok := next_arg(&args)
        if !arg_ok {
            break
        }

        switch arg {
        case "--track-alloc":
            prog_flags.track_alloc = true
        case:
            return
        }
    }

    return true
}

