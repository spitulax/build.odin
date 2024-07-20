package build_lib

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"


OS_Set :: bit_set[runtime.Odin_OS_Type]
SUPPORTED_OS :: OS_Set{.Linux}
#assert(ODIN_OS in SUPPORTED_OS)


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

    if !parse_args() {
        usage()
        ok = false
        return
    }

    context_allocator := context.allocator
    if g_prog_flags.track_alloc {
        mem.tracking_allocator_init(&mem_track, context_allocator)
        context_allocator = mem.tracking_allocator(&mem_track)
    }
    context.allocator = context_allocator

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

// TODO:docs `dependency` will be owned by `self` after this
stage_add_dependency :: proc(self: ^Stage, dependency: ^Stage) {
    dependency.parent = self
    append(&self.dependencies, dependency)
}

stage_clone :: proc(self: Stage, allocator := context.allocator) -> Stage {
    unimplemented()
}

stage_name :: proc(self: Stage) -> string {
    return(
        (self.name != "") \
        ? self.name \
        : fmt.tprintf("<%v:%v>", filepath.base(self.location.file_path), self.location.line) \
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

run_stages :: proc(root: ^Stage, location := #caller_location) -> (ok: bool) {
    return stage_eval(root, location)
}

destroy_stages :: proc(root: ^Stage) {
    for &dep in root.dependencies {
        destroy_stages(dep)
    }
    stage_destroy(root)
}

