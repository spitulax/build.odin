package build

import "base:runtime"
import "core:c/libc"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:sys/linux"
import "core:time"

_entry :: proc(start_func: proc() -> bool) {
    prog_flags, prog_flags_ok := _parse_args()
    if !prog_flags_ok {
        _usage()
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

_usage :: proc() {
    fmt.println("./build [options]...")
    fmt.println()
    fmt.println("Options:")
    fmt.println("    --help             Show this help")
    fmt.println("    --track-alloc      Track for unfreed and double freed memory")
}

_Prog_Flags :: struct {
    track_alloc: bool,
}

_parse_args :: proc() -> (flags: _Prog_Flags, ok: bool) {
    next_arg :: proc(args: ^[]string) -> (arg: string, ok: bool) {
        if len(args) <= 0 {
            return
        }
        arg = args^[0]
        args^ = args^[1:]
        return arg, true
    }

    prog_flags: _Prog_Flags

    args := os.args
    _ = next_arg(&args) or_return

    for {
        arg, arg_ok := next_arg(&args)
        if !arg_ok {
            break
        }

        switch arg {
        case "--help":
            return
        case "--track-alloc":
            prog_flags.track_alloc = true
        case:
            return
        }
    }

    return prog_flags, true
}

when ODIN_OS == .Linux {
    Exit :: distinct u32
    Signal :: distinct linux.Signal
    Process_Exit :: union #no_nil {
        Exit,
        Signal,
    }

    Process :: struct {
        pid:            linux.Pid,
        execution_time: time.Time,
    }
    process_wait :: proc(
        self: Process,
        location := #caller_location,
    ) -> (
        result: Process_Result,
        ok: bool,
    ) {
        for {
            status: u32
            if child_pid, errno := linux.waitpid(self.pid, &status, {}, nil); errno != .NONE {
                log.errorf(
                    "Process %v cannot exit: %s",
                    child_pid,
                    libc.strerror(i32(errno)),
                    location = location,
                )
                return
            }
            duration := time.since(self.execution_time)

            if linux.WIFSIGNALED(status) {
                result = {
                    exit     = Signal(linux.WTERMSIG(status)),
                    duration = duration,
                }
                ok = true
                return
            }

            if linux.WIFEXITED(status) {
                result = {
                    exit     = Exit(linux.WEXITSTATUS(status)),
                    duration = duration,
                }
                ok = true
                return
            }
        }
    }
    process_wait_many :: proc(
        processes: []Process,
        allocator := context.allocator,
        location := #caller_location,
    ) -> (
        results: []Process_Result,
        ok: bool,
    ) {
        ok = true
        defer if !ok {
            results = nil
        }
        results = make([]Process_Result, len(processes), allocator)
        for process, i in processes {
            process_result, process_ok := process_wait(process, location)
            ok &&= process_ok
            results[i] = process_result
        }
        return
    }

    Process_Result :: struct {
        exit:     Process_Exit,
        duration: time.Duration,
    }

    // TODO: add option capture stdout and stderr or silence the command
    run_cmd_async :: proc(
        cmd: []string,
        location := #caller_location,
    ) -> (
        process: Process,
        ok: bool,
    ) {
        if len(cmd) < 1 {
            log.error("Command is empty", location = location)
            return
        }

        argv := make([dynamic]cstring, 0, len(cmd) + 2)
        append(&argv, "/usr/bin/env")
        for arg in cmd {
            append(&argv, fmt.ctprintf("%s", arg))
        }
        append(&argv, nil)

        child_pid, fork_errno := linux.fork()
        if fork_errno != .NONE {
            log.errorf(
                "Failed to fork child process: %s",
                libc.strerror(i32(fork_errno)),
                location = location,
            )
            return
        }

        if child_pid == 0 {
            if errno := linux.execve(argv[0], raw_data(argv), _environ()); errno != .NONE {
                log.errorf(
                    "Failed to run `%s`: %s",
                    cmd,
                    libc.strerror(i32(errno)),
                    location = location,
                )
                linux.exit(1)
            }
            unreachable()
        }
        execution_time := time.now()

        delete(argv)
        return {pid = child_pid, execution_time = execution_time}, true
    }

    run_cmd_sync :: proc(
        cmd: []string,
        location := #caller_location,
    ) -> (
        result: Process_Result,
        ok: bool,
    ) {
        process := run_cmd_async(cmd, location) or_return
        return process_wait(process, location)
    }


    _Pipe :: struct {
        _both: [2]linux.Fd,
        read:  linux.Fd,
        write: linux.Fd,
    }
    _pipe_init :: proc(self: ^_Pipe) -> (ok: bool) {
        if errno := linux.pipe2(&self._both, {.CLOEXEC}); errno != .NONE {
            fmt.eprintfln("Failed to create pipes: %s", libc.strerror(i32(errno)))
            return false
        }
        self.read = self._both[0]
        self.write = self._both[1]
        return true
    }

    _environ :: proc() -> [^]cstring #no_bounds_check {
        env: [^]cstring = &runtime.args__[len(runtime.args__)]
        assert(env[0] == nil)
        return &env[1]
    }
}

