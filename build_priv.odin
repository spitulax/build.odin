//+private
package build_odin

import "base:intrinsics"
import "base:runtime"
import "core:encoding/ansi"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:reflect"
import "core:strconv"
import "core:strings"
import "core:sync"


g_process_tracker: ^Process_Tracker
g_process_tracker_mutex: ^sync.Mutex
g_shared_mem_arena: virtual.Arena
g_shared_mem_allocator: mem.Allocator
g_default_allocator: mem.Allocator
g_prog_flags: Prog_Flags
g_initialized: bool
FLAG_MAP_SEPARATOR :: ":"


Allocator :: runtime.Allocator
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


Option :: struct {
    value: Option_Type,
    desc:  string,
}

Option_Type :: union {
    i32,
    f32,
    string,
    bool,
    OS_Type,
    Arch_Type,
}

option_type_default :: proc($T: typeid) -> T where intrinsics.type_is_variant_of(Option_Type, T) {
    when T == i32 {
        return 0
    } else when T == f32 {
        return 0e0
    } else when T == string {
        return ""
    } else when T == bool {
        return false
    } else when T == OS_Type {
        return OS_Type.Unknown
    } else when T == Arch_Type {
        return Arch_Type.Unknown
    } else {
        unreachable()
    }
}

@(require_results)
option_set :: proc(key: string, value: Option_Type) -> (ok: bool) {
    context.allocator = g_default_allocator

    if _, get_ok := g_options[key]; !get_ok {
        log.errorf("Key `%s` does not exist", key, location = {})
        return
    }

    x := &g_options[key]
    switch v in value {
    case string:
        x.value = strings.clone(v)
    case i32, f32, bool, OS_Type, Arch_Type:
        x.value = v
    }

    return true
}

@(require_results)
option_set_from_str :: proc(key: string, value: string) -> (ok: bool) {
    context.allocator = g_default_allocator

    elem: Option
    elem_ok: bool
    if elem, elem_ok = g_options[key]; !elem_ok {
        log.errorf("Key `%s` does not exist", key, location = {})
        return
    }

    @(require_results)
    parse :: proc(x: ^Option, value: string, parser: proc(_: string) -> ($T, bool)) -> bool {
        parsed, parse_ok := parser(value)
        if !parse_ok {
            log.errorf("Failed to parse `%s` into %v", value, typeid_of(T), location = {})
            return false
        }
        x.value = parsed
        return true
    }

    x := &g_options[key]
    switch v in elem.value {
    case string:
        x.value = strings.clone(value)
    case i32:
        parse_int :: proc(s: string) -> (i32, bool) {
            parsed, ok := strconv.parse_int(s)
            return i32(parsed), ok
        }
        parse(x, value, parse_int) or_return
    case f32:
        parse_f32 :: proc(s: string) -> (f32, bool) {
            return strconv.parse_f32(s)
        }
        parse(x, value, parse_f32) or_return
    case bool:
        parse_bool :: proc(s: string) -> (bool, bool) {
            return strconv.parse_bool(s)
        }
        parse(x, value, parse_bool) or_return
    case Arch_Type:
        enum_val, enum_val_ok := reflect.enum_from_name(Arch_Type, value)
        if !enum_val_ok {
            log.errorf("`%s` does not exist in `Arch_Type`", value, location = {})
            return
        }
        x.value = enum_val
    case OS_Type:
        enum_val, enum_val_ok := reflect.enum_from_name(OS_Type, value)
        if !enum_val_ok {
            log.errorf("`%s` does not exist in `OS_Type`", value, location = {})
            log.errorf("Accepted values:", location = {})
            log.errorf(
                "     %s",
                concat_string_sep(reflect.enum_field_names(OS_Type), ", ", context.temp_allocator),
                location = {},
            )
            return
        }
        x.value = enum_val
    }

    return true
}

g_options: map[string]Option

g_options_destroy :: proc() {
    context.allocator = g_default_allocator

    for _, &val in g_options {
        #partial switch v in val.value {
        case string:
            delete(v)
        }
        delete(val.desc)
    }
    delete(g_options)
}


Flag_Type :: union #no_nil {
    ^int,
    ^string,
    ^bool,
    proc(_: string) -> bool,
}

Flag :: struct {
    name:      string,
    disp_name: string,
    ptr:       Flag_Type,
    desc:      string,
}

g_flags := []Flag {
    {
        name = "-D",
        disp_name = "-D <key>" + FLAG_MAP_SEPARATOR + "<value>",
        ptr = proc(a: string) -> bool {
            args := strings.split_n(a, FLAG_MAP_SEPARATOR, 2)
            defer delete(args)
            if len(args) != 2 {
                log.errorf("`%s` wrong amount of arguments", a, location = {})
                return false
            }
            option_set_from_str(args[0], args[1]) or_return
            return true
        },
        desc = "Override user-defined options",
    },
    {name = "--echo", ptr = &g_prog_flags.echo, desc = "Echo the command that is running"},
    {
        name = "--track-alloc",
        ptr = &g_prog_flags.track_alloc,
        desc = "Track for unfreed and double freed memory",
    },
    {
        name = "--verbose",
        ptr = &g_prog_flags.verbose,
        desc = "Echo the stage evaluations and executions",
    },
}

usage :: proc() {
    min_width :: 10
    names := make([dynamic]string)
    defer delete(names)
    for x in g_flags {
        append(&names, x.disp_name if x.disp_name != "" else x.name)
    }
    for k, _ in g_options {
        append(&names, k)
    }
    max_width := min_width
    for x in names {
        max_width = max(len(x), max_width)
    }

    fmt.println("./build [options]...")
    fmt.println()
    if len(g_options) > 0 {
        fmt.println("User-defined options:")
        for k, v in g_options {
            fmt.print("    ")
            fmt.print(k)
            for _ in 0 ..< max_width - len(k) + 4 {
                fmt.print(" ")
            }
            fmt.print(v.desc)
            type := reflect.union_variant_typeid(v.value)
            fmt.printf(" (%v)", type)
            if _, ti_ok := runtime.type_info_base(type_info_of(type)).variant.(runtime.Type_Info_Enum);
               ti_ok {
                names := reflect.enum_field_names(type)
                fmt.println()
                for x, i in names {
                    if i > 0 {
                        fmt.println()
                    }
                    fmt.printf("        - %s", x)
                }
            }
            fmt.println()
        }
        fmt.println()
    }
    fmt.println("Flags:")
    for x in g_flags {
        name := x.disp_name if x.disp_name != "" else x.name
        fmt.print("    ")
        fmt.print(name)
        for _ in 0 ..< max_width - len(name) + 4 {
            fmt.print(" ")
        }
        fmt.print(x.desc)
        fmt.println()
    }
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

        success := false
        for flag in g_flags {
            if flag.name == arg {
                success = true
                switch v in flag.ptr {
                case ^bool:
                    v^ = true
                case ^int:
                    unimplemented()
                case ^string:
                    unimplemented()
                case proc(_: string) -> bool:
                    arg, arg_ok = next_arg(&args)
                    v(arg) or_return
                }
                break
            }
        }
        if !success || !arg_ok {return}
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

