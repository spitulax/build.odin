package build_lib

import "base:runtime"
import "core:encoding/ansi"
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
    context.logger = create_console_logger()
    shared_mem, shared_mem_size, shared_mem_ok := process_tracker_init()
    if !shared_mem_ok {
        ok = false
        return
    }

    defer {
        process_tracker_destroy(shared_mem, shared_mem_size)
        free_all(context.temp_allocator)
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

    if !start_func() {
        ok = false
        return
    }

    assert(len(g_process_tracker) == 0)
    ok = true
    return
}


Exit :: _Exit
Signal :: _Signal
Process_Exit :: _Process_Exit
Process_Handle :: _Process_Handle


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
    stderr:   string, // I didn't make them both Maybe() for "convenience" when accessing them
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


@(private)
process_tracker_init :: proc() -> (shared_mem: rawptr, shared_mem_size: uint, ok: bool) {
    return _process_tracker_init()
}

@(private)
process_tracker_destroy :: proc(shared_mem: rawptr, size: uint) -> (ok: bool) {
    return _process_tracker_destroy(shared_mem, size)
}


@(private)
Default_Logger_Opts :: log.Options{.Level, .Terminal_Color, .Short_File_Path, .Line, .Procedure}

@(private)
Term_Color_Enum :: enum {
    Reset,
    Red,
    Yellow,
    Dark_Grey,
}
@(private)
TERM_COLOR := [Term_Color_Enum]string {
    .Reset     = ansi.CSI + ansi.RESET + ansi.SGR,
    .Red       = ansi.CSI + ansi.FG_RED + ansi.SGR,
    .Yellow    = ansi.CSI + ansi.FG_YELLOW + ansi.SGR,
    .Dark_Grey = ansi.CSI + ansi.FG_BRIGHT_BLACK + ansi.SGR,
}

@(private)
log_header :: proc(
    backing: []byte,
    options: log.Options,
    level: log.Level,
    location := #caller_location,
) -> strings.Builder {
    buf := strings.builder_from_bytes(backing)

    LEVEL_HEADERS := [?]string {
        0 ..< 10 = "[DEBUG]",
        10 ..< 20 = "[INFO]",
        20 ..< 30 = "[WARN]",
        30 ..< 40 = "[ERROR]",
        40 ..< 50 = "[FATAL]",
    }
    col := TERM_COLOR[.Reset]
    switch level {
    case .Debug:
        col = TERM_COLOR[.Dark_Grey]
    case .Info:
        col = TERM_COLOR[.Reset]
    case .Warning:
        col = TERM_COLOR[.Yellow]
    case .Error, .Fatal:
        col = TERM_COLOR[.Red]
    }
    fmt.sbprint(&buf, col)
    fmt.sbprint(&buf, LEVEL_HEADERS[level])

    log.do_location_header(options, &buf, location)
    return buf
}

@(private)
create_console_logger :: proc() -> log.Logger {
    console_logger_proc :: proc(
        logger_data: rawptr,
        level: log.Level,
        text: string,
        options: log.Options,
        location := #caller_location,
    ) {
        _ = logger_data
        backing: [1024]byte
        buf := log_header(backing[:], options, level, location)
        fd := (level >= log.Level.Error) ? os.stderr : os.stdout
        fmt.fprintfln(fd, "%s%s%s", strings.to_string(buf), text, TERM_COLOR[.Reset])
    }

    return log.Logger{console_logger_proc, nil, log.Level.Debug, Default_Logger_Opts}
}

@(private)
Builder_Logger_Data :: struct {
    builder: ^strings.Builder,
    mutex:   Maybe(^sync.Mutex),
}

@(private)
create_builder_logger :: proc(
    builder: ^strings.Builder,
    allocator := context.allocator,
    mutex: Maybe(^sync.Mutex),
) -> log.Logger {
    assert(builder != nil)

    builder_logger_proc :: proc(
        logger_data: rawptr,
        level: log.Level,
        text: string,
        options: log.Options,
        location := #caller_location,
    ) {
        data := cast(^Builder_Logger_Data)logger_data
        backing: [1024]byte
        buf := log_header(backing[:], options, level, location)
        mutex, mutex_ok := data.mutex.?
        if mutex_ok {
            sync.mutex_lock(mutex)
        }
        fmt.sbprintf(data.builder, "%s%s%s", strings.to_string(buf), text, TERM_COLOR[.Reset])
        if mutex_ok {
            sync.mutex_unlock(mutex)
        }
    }

    // NOTE: I only intend to allocate this to the shared arena for now
    data := new(Builder_Logger_Data, allocator)
    data^ = {
        builder = builder,
        mutex   = mutex,
    }
    return log.Logger{builder_logger_proc, data, log.Level.Debug, Default_Logger_Opts}
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

