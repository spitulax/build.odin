//+private
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


g_process_tracker: ^Process_Tracker
g_process_tracker_mutex: ^sync.Mutex
g_shared_mem_arena: virtual.Arena
g_shared_mem_allocator: mem.Allocator
g_prog_flags: Prog_Flags


Location :: runtime.Source_Code_Location


Process_Tracker :: #type map[Process_Handle]^Process_Status
Process_Status :: struct {
    has_run: bool,
    log:     strings.Builder,
}


process_tracker_init :: proc() -> (shared_mem: rawptr, shared_mem_size: uint, ok: bool) {
    return _process_tracker_init()
}

process_tracker_destroy :: proc(shared_mem: rawptr, size: uint) -> (ok: bool) {
    return _process_tracker_destroy(shared_mem, size)
}


stage_eval :: proc(self: ^Stage, location: Location) -> (ok: bool) {
    if self.status != .Unevaluated {return}
    if g_prog_flags.verbose {
        log.debugf("Evaluating stage `%s`", stage_name(self^), location = location)
    }
    self.status = .Waiting
    for &dep in self.dependencies {
        stage_eval(dep, location)
        if dep.status == .Failed {
            msg := fmt.tprintf(
                "Failed to run stage `%s` needed by `%s`",
                stage_name(dep^),
                concat_string_sep(
                    stage_parents(dep, context.temp_allocator),
                    " -> ",
                    context.temp_allocator,
                ),
            )
            if dep.require {
                log.error(msg, location = location)
                self.status = .Failed
                return false
            } else {
                log.warn(msg, location = location)
            }
        }
    }
    if g_prog_flags.verbose {
        log.debugf("Running stage `%s`", stage_name(self^), location = location)
    }
    if self.status != .Failed {
        self.status = (self.procedure(self, self.userdata)) ? .Success : .Failed
    }
    return true
}

stage_destroy :: proc(self: ^Stage) {
    delete(self.name)
    delete(self.dependencies)
}


Default_Logger_Opts :: log.Options{.Level, .Terminal_Color, .Short_File_Path, .Line}

Term_Color_Enum :: enum {
    Reset,
    Red,
    Yellow,
    Dark_Grey,
}
TERM_COLOR := [Term_Color_Enum]string {
    .Reset     = ansi.CSI + ansi.RESET + ansi.SGR,
    .Red       = ansi.CSI + ansi.FG_RED + ansi.SGR,
    .Yellow    = ansi.CSI + ansi.FG_YELLOW + ansi.SGR,
    .Dark_Grey = ansi.CSI + ansi.FG_BRIGHT_BLACK + ansi.SGR,
}

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

Builder_Logger_Data :: struct {
    builder: ^strings.Builder,
    mutex:   Maybe(^sync.Mutex),
}

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


usage :: proc() {
    fmt.println("./build [options]...")
    fmt.println()
    fmt.println("Options:")
    fmt.println("    --track-alloc      Track for unfreed and double freed memory")
    fmt.println("    --echo             Echo the command that is running")
    fmt.println("    --verbose          Echo the stage evaluations and executions")
}

Prog_Flags :: struct {
    track_alloc: bool,
    echo:        bool,
    verbose:     bool,
}

@(require_results)
parse_args :: proc() -> (ok: bool) {
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
            g_prog_flags.track_alloc = true
        case "--echo":
            g_prog_flags.echo = true
        case "--verbose":
            g_prog_flags.verbose = true
        case:
            return
        }
    }

    return true
}


concat_string_sep :: proc(strs: []string, sep: string, allocator := context.allocator) -> string {
    sb: strings.Builder
    strings.builder_init(&sb, allocator)
    for str, i in strs {
        if i > 0 {
            fmt.sbprint(&sb, sep)
        }
        fmt.sbprint(&sb, str)
    }
    return strings.to_string(sb)
}
