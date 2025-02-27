package build_odin

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:path/slashpath"
import "core:reflect"
import "core:strings"
import "core:time"


OS_Set :: bit_set[runtime.Odin_OS_Type]
SUPPORTED_OS :: OS_Set{.Linux}
#assert(ODIN_OS in SUPPORTED_OS)


OS_Type :: distinct runtime.Odin_OS_Type
Arch_Type :: distinct runtime.Odin_Arch_Type
Optimization_Type :: distinct runtime.Odin_Optimization_Mode
Start_Proc :: #type proc() -> bool

start :: proc(start_proc: Start_Proc) {
    ok: bool = true
    mem_track: mem.Tracking_Allocator
    context.logger = create_console_logger()
    shared_mem, shared_mem_size, shared_mem_ok := process_tracker_init()
    if !shared_mem_ok {
        ok = false
        return
    }

    defer {
        g_options_destroy()
        process_tracker_destroy(shared_mem, shared_mem_size)
        free_all(context.temp_allocator)
        if g_prog_flags.track_alloc {
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

    context_allocator := context.allocator
    if g_prog_flags.track_alloc {
        mem.tracking_allocator_init(&mem_track, context_allocator)
        context_allocator = mem.tracking_allocator(&mem_track)
    }
    context.allocator = context_allocator
    g_default_allocator = context_allocator

    if !init_allocators() {
        return
    }

    g_initialized = true

    if !parse_args() {
        usage()
        ok = false
        return
    }

    if !start_proc() {
        ok = false
        return
    }

    assert(len(g_process_tracker) == 0)
    ok = true
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
    stdout:   string, // both are "" if run_prog_* is not capturing
    stderr:   string, // I didn't make them both Maybe() for "convenience" when accessing them
}

process_result_destroy :: proc(self: ^Process_Result, location := #caller_location) {
    _process_result_destroy(self, location)
}

process_result_destroy_many :: proc(selves: []Process_Result, location := #caller_location) {
    _process_result_destroy_many(selves, location)
}


// FIXME: *some* programs that read from stdin may hang if called with .Silent or .Capture
Run_Prog_Option :: enum {
    Share,
    Silent,
    Capture,
}

run_prog_async :: proc {
    run_prog_async_unchecked,
    run_prog_async_checked,
}

run_prog_sync :: proc {
    run_prog_sync_unchecked,
    run_prog_sync_checked,
}

run_prog_async_unchecked :: proc(
    prog: string,
    args: []string = nil,
    option: Run_Prog_Option = .Share,
    location := #caller_location,
) -> (
    process: Process,
    ok: bool,
) {
    return _run_prog_async_unchecked(prog, args, option, location)
}

// `process` is empty or {} if `cmd` is not found
run_prog_async_checked :: proc(
    prog: Program,
    args: []string = nil,
    option: Run_Prog_Option = .Share,
    require: bool = true,
    location := #caller_location,
) -> (
    process: Process,
    ok: bool,
) {
    if !check_program(prog, require, location) {
        return {}, !require
    }
    return _run_prog_async_unchecked(prog.name, args, option, location)
}

run_prog_sync_unchecked :: proc(
    prog: string,
    args: []string = nil,
    option: Run_Prog_Option = .Share,
    allocator := context.allocator,
    location := #caller_location,
) -> (
    result: Process_Result,
    ok: bool,
) {
    process := run_prog_async_unchecked(prog, args, option, location) or_return
    return process_wait(process, allocator, location)
}

// `result` is empty or {} if `cmd` is not found
run_prog_sync_checked :: proc(
    prog: Program,
    args: []string = nil,
    option: Run_Prog_Option = .Share,
    allocator := context.allocator,
    require: bool = true,
    location := #caller_location,
) -> (
    result: Process_Result,
    ok: bool,
) {
    if !check_program(prog, require, location) {
        return {}, !require
    }
    process := run_prog_async_unchecked(prog.name, args, option, location) or_return
    return process_wait(process, allocator, location)
}


Program :: struct {
    found: bool,
    name:  string,
    //full_path: string, // would require allocation
}

@(require_results)
program :: proc($name: string, location := #caller_location) -> Program {
    return _program(name, location)
}

@(require_results)
check_program :: proc(
    prog: Program,
    require: bool = true,
    location := #caller_location,
) -> (
    found: bool,
) {
    if !prog.found {
        msg := fmt.tprintf("`%v` does not exist", prog.name)
        if require {
            log.error(msg, location = location)
        } else {
            log.warn(msg, location = location)
        }
        return
    }
    return true
}


Stage :: struct {
    name:         string,
    parent:       ^Stage,
    dependencies: [dynamic]^Stage,
    procedure:    Stage_Proc,
    userdata:     rawptr,
    require:      bool,
    status:       Stage_Status,
    location:     Location,
    allocator:    runtime.Allocator,
}

Stage_Status :: enum {
    Unevaluated,
    Waiting,
    Success,
    Failed,
}

Stage_Proc :: #type proc(self: ^Stage, userdata: rawptr) -> (ok: bool)

stage_make :: proc(
    procedure: Stage_Proc,
    name: string = "",
    userdata: rawptr = nil,
    require: bool = true,
    allocator := context.allocator,
    location := #caller_location,
) -> Stage {
    return Stage {
        procedure = procedure,
        name = strings.clone(name, allocator),
        userdata = userdata,
        require = require,
        status = .Unevaluated,
        dependencies = make([dynamic]^Stage, allocator),
        allocator = allocator,
        location = location,
    }
}

// DOCS: `dependency` will be owned by `self` after this
stage_add_dependency :: proc(self: ^Stage, dependency: ^Stage) {
    dependency.parent = self
    append(&self.dependencies, dependency)
}

stage_clone :: proc(self: Stage, allocator := context.allocator) -> Stage {
    unimplemented()
}

stage_name :: proc(self: Stage) -> string {
    return(
        (self.name != "") ? self.name : fmt.tprintf("<%v:%v>", filepath.base(self.location.file_path), self.location.line) \
    )
}

stage_parents :: proc(self: ^Stage, allocator := context.allocator) -> []string {
    result := make([dynamic]string, allocator)
    cur := self.parent
    for {
        if cur == nil {break}
        append(&result, stage_name(cur^))
        cur = cur.parent
    }
    return result[:]
}

print_stage_tree :: proc(root: ^Stage) {
    unimplemented()
}

run_stage :: proc(stage: ^Stage, location := #caller_location) -> (ok: bool) {
    return stage_eval(stage, false, location)
}

run_stages :: proc(root: ^Stage, location := #caller_location) -> (ok: bool) {
    return stage_eval(root, true, location)
}

destroy_stages :: proc(root: ^Stage) {
    for &dep in root.dependencies {
        destroy_stages(dep)
    }
    stage_destroy(root)
}


// DOCS: this procedure can only be called before start()
option_add :: proc {
    option_add_default,
    option_add_nodefault,
}

option_add_default :: proc(
    key: string,
    $T: typeid,
    default: T,
    desc: string,
) where intrinsics.type_is_variant_of(Option_Type, T) {
    if g_initialized {
        log.warnf("`%s` should be called before the start procedure", #procedure, location = {})
        return
    }

    if _, get_ok := g_options[key]; get_ok {
        //fmt.eprintfln("Option `%s` already exist, ignoring", key)
        return
    }
    value: Option_Type = default
    g_options[key] = {
        value = value,
        desc  = strings.clone(desc),
    }
}

option_add_nodefault :: proc(key: string, $T: typeid, desc: string) {
    option_add_default(key, T, option_type_default(T), desc)
}

option_get :: proc(
    key: string,
    $type: typeid,
    loc := #caller_location,
) -> (
    value: type,
    ok: bool,
) {
    elem: Option
    elem_ok: bool
    if elem, elem_ok = g_options[key]; !elem_ok {
        log.errorf("Key `%s` does not exist", key, location = loc)
        return
    }
    value_unwrapped, unwrap_ok := elem.value.(type)
    if !unwrap_ok {
        log.errorf(
            "Could not unwrap the value of `%s` to type %v",
            key,
            typeid_of(type),
            location = loc,
        )
        return
    }
    value = value_unwrapped
    ok = true
    return
}

// DOCS: for debugging purpose
options_print :: proc() {
    for k, v in g_options {
        log.debugf("- %s:%v = %#v", k, reflect.union_variant_typeid(v.value), v.value)
    }
}


// NOTE: must use forward slashes
Filepath :: distinct string

path :: proc(path: string, location := #caller_location) -> (res: Filepath, ok: bool) {
    return _path(path, location)
}

verify_paths :: proc(paths: []Filepath, location := #caller_location) -> (ok: bool) {
    for &x in paths {
        x = path(string(x), location) or_return
    }
    ok = true
    return
}

is_path_absolute :: proc(path: Filepath) -> bool {
    return _is_path_absolute(path)
}

filepaths_clear :: proc() {
    virtual.arena_free_all(&g_paths_arena)
}


File_Stat :: struct {
    modtime: time.Time,
}

file_stat :: proc(path: Filepath, location: Location) -> (res: File_Stat, ok: bool) {
    return _file_stat(path, location)
}


Builder :: struct {
    name:         string,
    target:       []Filepath,
    source:       []Filepath,
    extra_prereq: []Filepath,
    procedure:    Builder_Proc,
    userdata:     rawptr,
}

// TODO: should we add `userdata`?
Builder_Proc :: #type proc(self: ^Builder, stage: ^Stage) -> (ok: bool)

builder_verify :: proc(self: ^Builder) -> (ok: bool) {
    verify_paths(self.target) or_return
    verify_paths(self.source) or_return
    verify_paths(self.extra_prereq) or_return
    return true
}

builder_stage :: proc(
    self: ^Builder,
    require: bool = true,
    allocator := context.allocator,
    location := #caller_location,
) -> Stage {
    builder_verify(self)
    return stage_make(builder_proc, self.name, self, require, allocator, location)
}

builder_proc :: proc(self: ^Stage, userdata: rawptr) -> bool {
    builder := cast(^Builder)userdata
    return builder->procedure(self)
}

builder_run :: proc(self: ^Builder, location := #caller_location) -> (ok: bool) {
    stage := builder_stage(self, location = location)
    defer stage_destroy(&stage)
    return run_stages(&stage, location)
}


build_dir :: proc(location := #caller_location) -> (dirpath: Filepath, ok: bool) {
    if !os.is_dir("./build") {
        if os.exists("./build") {
            log.error("./build exists but it is not a directory", location = location)
            return
        }
        if err := os.make_directory("./build"); err != nil {
            log.error("Failed to create build directory:", err, location = location)
            return
        }
        if g_prog_flags.verbose {
            log.debugf(
                "Created build directory at `%s`",
                string(path("./build") or_return),
                location = location,
            )
        }
    }
    // TODO: allocates duplicate every call
    return path("./build") or_return, true
}

// DOCS: mkdir -p
make_target_directory :: proc(
    name: string,
    location := #caller_location,
) -> (
    dirpath: Filepath,
    ok: bool,
) {
    bd := build_dir() or_return
    ps := slashpath.split_elements(name)
    for i in 0 ..< len(ps) {
        cur_p := make([]string, i + i)
        defer delete(cur_p)
        cur_p[0] = string(bd)
        for j := i; j > 0; j -= 1 {
            cur_p[j] = ps[i - j - 1]
        }
        log.info(cur_p)
        p := slashpath.join(cur_p)
        defer delete(p)
        if !os.is_dir(p) {
            if os.exists(p) {
                log.errorf("`%s` exists but it is not a directory", p, location = location)
                return
            }
            if err := os.make_directory(p); err != nil {
                log.error("Failed to create build directory:", err, location = location)
                return
            }
            if g_prog_flags.verbose {
                log.debugf("Created irectory at `%s`", p, location = location)
            }
        }
    }
    return path("") or_return, true
}

