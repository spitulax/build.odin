package build_lib

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:sync"
import "core:time"

OS_Set :: bit_set[runtime.Odin_OS_Type]
SUPPORTED_OS :: OS_Set{.Linux}
#assert(ODIN_OS in SUPPORTED_OS)

Start_Func :: #type proc() -> bool

run :: proc(start_func: Start_Func) {
    ok: bool = true
    prog_flags: Prog_Flags
    mem_track: mem.Tracking_Allocator
    shared_mem, shared_mem_size, shared_mem_ok := process_tracker_init()
    if !shared_mem_ok {
        ok = false
        return
    }
    console_logger := log.create_console_logger()
    defer {
        process_tracker_destroy(shared_mem, shared_mem_size)
        free_all(context.temp_allocator)
        log.destroy_console_logger(console_logger)
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

    if !parse_args(&prog_flags) {
        usage()
        ok = false
        return
    }

    context_allocator := context.allocator
    if prog_flags.track_alloc {
        mem.tracking_allocator_init(&mem_track, context_allocator)
        context_allocator = mem.tracking_allocator(&mem_track)
    }
    context.allocator = context_allocator
    context.logger = console_logger

    if !start_func() {
        ok = false
        return
    }

    assert(len(g_process_tracker) == 0)
    ok = true
    return
}

@(private)
usage :: proc() {
    fmt.println("./build [options]...")
    fmt.println()
    fmt.println("Options:")
    fmt.println("    --track-alloc      Track for unfreed and double freed memory")
}

@(private)
Prog_Flags :: struct {
    track_alloc: bool,
}

@(private, require_results)
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


Process :: struct {
    using _impl:    _Process,
    execution_time: time.Time,
}

process_handle :: proc(self: Process) -> Process_Handle {
    return _process_handle(self)
}

process_wait :: proc(
    self: Process,
    allocator := context.allocator,
    location := #caller_location,
) -> (
    result: Process_Result,
    ok: bool,
) {
    return _process_wait(self, allocator, location)
}

process_wait_many :: proc(
    selves: []Process,
    allocator := context.allocator,
    location := #caller_location,
) -> (
    results: []Process_Result,
    ok: bool,
) {
    return _process_wait_many(selves, allocator, location)
}


Process_Result :: struct {
    exit:     Process_Exit, // nil on success
    duration: time.Duration,
    stdout:   string, // both are "" if run_cmd_* is not capturing
    stderr:   string,
}

process_result_destroy :: proc(self: ^Process_Result, location := #caller_location) {
    _process_result_destroy(self, location)
}

process_result_destroy_many :: proc(selves: []Process_Result, location := #caller_location) {
    _process_result_destroy_many(selves, location)
}


// FIXME: *some* programs that read from stdin may hang if called with .Silent or .Capture
Run_Cmd_Option :: enum {
    Share,
    Silent,
    Capture,
}

run_cmd_async :: proc(
    cmd: []string,
    option: Run_Cmd_Option = .Share,
    location := #caller_location,
) -> (
    process: Process,
    ok: bool,
) {
    return _run_cmd_async(cmd, option, location)
}

run_cmd_sync :: proc(
    cmd: []string,
    option: Run_Cmd_Option = .Share,
    allocator := context.allocator,
    location := #caller_location,
) -> (
    result: Process_Result,
    ok: bool,
) {
    process := run_cmd_async(cmd, option, location) or_return
    return process_wait(process, allocator, location)
}


@(private)
Process_Tracker :: #type map[Process_Handle]Process_Status
@(private)
g_process_tracker: ^Process_Tracker
@(private)
g_process_tracker_mutex: ^sync.Mutex
@(private)
g_shared_mem_arena: virtual.Arena
@(private)
g_shared_mem_allocator: mem.Allocator


@(private)
Process_Status :: struct {
    has_run: bool,
    log:     strings.Builder,
}

