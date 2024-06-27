package build_lib

import "base:runtime"
import "core:c/libc"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:mem/virtual"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:sys/linux"
import "core:time"

// (hopefully) unique exit code that indicates that a child process
// exited before being taken over by execve or execve returns error.
// TODO: instead of this maybe track subprocesses using some sort of global variable?
@(private = "file")
EXIT_BEFORE_EXEC :: 240


@(private = "file")
STDIN_FILENO :: 0
@(private = "file")
STDOUT_FILENO :: 1
@(private = "file")
STDERR_FILENO :: 2


@(private = "file")
Exit :: distinct u32
@(private = "file")
Signal :: distinct linux.Signal
Process_Exit :: union {
    Exit,
    Signal,
}
Process_Handle :: linux.Pid


_Process :: struct {
    pid:         Process_Handle,
    stdout_pipe: Maybe(Pipe),
    stderr_pipe: Maybe(Pipe),
}

_process_handle :: proc(self: Process) -> Process_Handle {
    return self.pid
}

_process_wait :: proc(
    self: Process,
    allocator := context.allocator,
    location := #caller_location,
) -> (
    result: Process_Result,
    ok: bool,
) {
    for {
        status: u32
        early_exit: bool
        if child_pid, errno := linux.waitpid(self.pid, &status, {}, nil); errno != .NONE {
            log.errorf(
                "Process %v cannot exit: %s",
                child_pid,
                libc.strerror(i32(errno)),
                location = location,
            )
            early_exit = true
        }
        result.duration = time.since(self.execution_time)

        current: ^Process_Status
        child_appended: bool
        if sync.mutex_guard(g_process_tracker_mutex) {
            if len(g_process_tracker^) <= 0 {
                child_appended = false
            } else {
                current = &g_process_tracker[self.pid]
                child_appended = true
            }
        }

        defer if sync.mutex_guard(g_process_tracker_mutex) {
            delete_key(g_process_tracker, self.pid)
        }

        if linux.WIFSIGNALED(status) || linux.WIFEXITED(status) {
            stdout_pipe, stdout_pipe_ok := self.stdout_pipe.?
            stderr_pipe, stderr_pipe_ok := self.stderr_pipe.?
            if stdout_pipe_ok || stderr_pipe_ok {
                assert(
                    stderr_pipe_ok == stdout_pipe_ok,
                    "stdout and stderr pipe aren't equally initialized",
                )
                result.stdout = pipe_read(&stdout_pipe, location, allocator) or_return
                result.stderr = pipe_read(&stderr_pipe, location, allocator) or_return
                pipe_close_read(&stdout_pipe, location) or_return
                pipe_close_read(&stderr_pipe, location) or_return
            }

            // short-circuit evaluation
            if !(child_appended && sync.atomic_load(&current.has_run)) {
                early_exit = true
                log.errorf(
                    "Process %v did not execute the command successfully",
                    self.pid,
                    location = location,
                )
                log_str: string
                if child_appended {
                    if sync.mutex_guard(g_process_tracker_mutex) {
                        log_str = strings.to_string(current.log)
                    }
                }
                log.errorf("Info: %s", log_str if child_appended else "", location = location)
            }
        }

        if linux.WIFSIGNALED(status) {
            result.exit = Signal(linux.WTERMSIG(status))
            ok = true && !early_exit
            return
        }

        if linux.WIFEXITED(status) {
            exit_code := linux.WEXITSTATUS(status)
            result.exit = (exit_code == 0) ? nil : Exit(exit_code)
            ok = true && !early_exit
            return
        }
    }
}

_process_wait_many :: proc(
    selves: []Process,
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
    results = make([]Process_Result, len(selves), allocator, location)
    for process, i in selves {
        process_result, process_ok := process_wait(process, allocator, location)
        ok &&= process_ok
        results[i] = process_result
    }
    return
}


_process_result_destroy :: proc(self: ^Process_Result, location := #caller_location) {
    delete(self.stdout, loc = location)
    delete(self.stderr, loc = location)
}

_process_result_destroy_many :: proc(selves: []Process_Result, location := #caller_location) {
    for &result in selves {
        process_result_destroy(&result, location)
    }
}


_run_cmd_async :: proc(
    cmd: []string,
    option: Run_Cmd_Option = .Share,
    location := #caller_location,
) -> (
    process: Process,
    ok: bool,
) {
    if len(cmd) < 1 {
        log.error("Command is empty", location = location)
        return
    }

    stdout_pipe, stderr_pipe: Pipe
    dev_null: linux.Fd
    if option == .Capture || option == .Silent {
        dev_null_errno: linux.Errno
        dev_null, dev_null_errno = linux.open(
            "/dev/null",
            {.RDWR, .CREAT},
            {.IWUSR, .IWGRP, .IWOTH},
        )
        assert(dev_null_errno == .NONE, "could not open /dev/null")
    }
    if option == .Capture {
        pipe_init(&stdout_pipe, location) or_return
        pipe_init(&stderr_pipe, location) or_return
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
        fail :: proc() {
            linux.exit(1)
        }

        pid := linux.getpid()
        status := Process_Status{}
        _, builder_err := strings.builder_init_none(&status.log, g_shared_mem_allocator)
        assert(builder_err == .None)
        current: ^Process_Status
        if sync.mutex_guard(g_process_tracker_mutex) {
            assert(g_process_tracker != nil || g_process_tracker_mutex != nil)
            g_process_tracker[pid] = status
            current = &g_process_tracker[pid]
        }

        // TODO: fix logging from child processes. Create a logger that appends to Process_Status.log

        switch option {
        case .Share:
            break
        case .Silent:
            if !fd_redirect(dev_null, STDOUT_FILENO, location) {fail()}
            if !fd_redirect(dev_null, STDERR_FILENO, location) {fail()}
            if !fd_redirect(dev_null, STDIN_FILENO, location) {fail()}
            if !fd_close(dev_null, location) {fail()}
        case .Capture:
            if !pipe_close_read(&stdout_pipe, location) {fail()}
            if !pipe_close_read(&stderr_pipe, location) {fail()}

            if !pipe_redirect(&stdout_pipe, STDOUT_FILENO, location) {fail()}
            if !pipe_redirect(&stderr_pipe, STDERR_FILENO, location) {fail()}
            if !fd_redirect(dev_null, STDIN_FILENO, location) {fail()}

            if !pipe_close_write(&stdout_pipe, location) {fail()}
            if !pipe_close_write(&stderr_pipe, location) {fail()}
            if !fd_close(dev_null, location) {fail()}
        }

        _, exch_ok := sync.atomic_compare_exchange_strong(&current.has_run, false, true)
        assert(exch_ok)
        if errno := linux.execve(argv[0], raw_data(argv), environ()); errno != .NONE {
            _, exch_ok = sync.atomic_compare_exchange_strong(&current.has_run, true, false)
            assert(exch_ok)
            log.errorf(
                "Failed to run `%s`: %s",
                cmd,
                libc.strerror(i32(errno)),
                location = location,
            )
            fail()
        }
        unreachable()
    }
    execution_time := time.now()

    if option == .Capture || option == .Silent {
        fd_close(dev_null, location) or_return
    }

    delete(argv, loc = location)
    maybe_stdout_pipe: Maybe(Pipe) = (option == .Capture) ? stdout_pipe : nil
    maybe_stderr_pipe: Maybe(Pipe) = (option == .Capture) ? stderr_pipe : nil
    return {
            pid = child_pid,
            execution_time = execution_time,
            stdout_pipe = maybe_stdout_pipe,
            stderr_pipe = maybe_stderr_pipe,
        },
        true
}


@(private)
process_tracker_init :: proc() -> (shared_mem: rawptr, shared_mem_size: uint, ok: bool) {
    PROCESS_TRACKER_SIZE :: 1 * mem.Megabyte

    mem_errno: linux.Errno
    shared_mem, mem_errno = linux.mmap(
        0,
        PROCESS_TRACKER_SIZE,
        {.READ, .WRITE},
        {.SHARED, .ANONYMOUS},
        linux.Fd(-1),
    )
    if mem_errno != .NONE {
        log.errorf("Failed to map shared memory: %s", libc.strerror(i32(mem_errno)))
        return
    }

    arena_err := virtual.arena_init_buffer(
        &g_shared_mem_arena,
        slice.bytes_from_ptr(shared_mem, PROCESS_TRACKER_SIZE),
    )
    if arena_err != .None {
        log.errorf("Failed to initialized arena from shared memory: %v", arena_err)
        return
    }
    context.allocator = virtual.arena_allocator(&g_shared_mem_arena)
    g_shared_mem_allocator = context.allocator

    g_process_tracker = new(Process_Tracker)
    // FIXME: when the map reallocates past the initial capacity,
    // the next child process trying to append to it will segfault and leave the mutex locked, creating a deadlock
    _ = reserve(g_process_tracker, 128)

    // yep
    process_tracker_mutex := sync.Mutex{}
    process_tracker_mutex_rawptr, _ := mem.alloc(size_of(sync.Mutex))
    process_tracker_mutex_ptr_rawptr, _ := mem.alloc(size_of(^sync.Mutex))
    g_process_tracker_mutex = cast(^sync.Mutex)process_tracker_mutex_ptr_rawptr
    g_process_tracker_mutex =
    cast(^sync.Mutex)libc.memmove(
        process_tracker_mutex_rawptr,
        &process_tracker_mutex,
        size_of(sync.Mutex),
    )

    return shared_mem, PROCESS_TRACKER_SIZE, true
}

@(private)
process_tracker_destroy :: proc(shared_mem: rawptr, size: uint) -> (ok: bool) {
    if shared_mem != nil {
        if errno := linux.munmap(shared_mem, size); errno != .NONE {
            log.errorf("Failed to unmap shared memory: %s", libc.strerror(i32(errno)))
            return
        }
    }
    return true
}


@(private = "file")
Pipe :: struct {
    _both: [2]linux.Fd,
    read:  linux.Fd,
    write: linux.Fd,
}

@(private = "file", require_results)
pipe_init :: proc(self: ^Pipe, location: runtime.Source_Code_Location) -> (ok: bool) {
    if errno := linux.pipe2(&self._both, {.CLOEXEC}); errno != .NONE {
        log.errorf("Failed to create pipes: %s", libc.strerror(i32(errno)), location = location)
        return false
    }
    self.read = self._both[0]
    self.write = self._both[1]
    return true
}

@(private = "file", require_results)
pipe_close_read :: proc(self: ^Pipe, location: runtime.Source_Code_Location) -> (ok: bool) {
    if errno := linux.close(self.read); errno != .NONE {
        log.errorf("Failed to close read pipe: %s", libc.strerror(i32(errno)), location = location)
        return false
    }
    return true
}

@(private = "file", require_results)
pipe_close_write :: proc(self: ^Pipe, location: runtime.Source_Code_Location) -> (ok: bool) {
    if errno := linux.close(self.write); errno != .NONE {
        log.errorf(
            "Failed to close write pipe: %s",
            libc.strerror(i32(errno)),
            location = location,
        )
        return false
    }
    return true
}

@(private = "file", require_results)
pipe_redirect :: proc(
    self: ^Pipe,
    newfd: linux.Fd,
    location: runtime.Source_Code_Location,
) -> (
    ok: bool,
) {
    if _, errno := linux.dup2(self.write, newfd); errno != .NONE {
        log.errorf(
            "Failed to redirect oldfd: %v, newfd: %v: %s",
            self.write,
            newfd,
            libc.strerror(i32(errno)),
            location = location,
        )
        return false
    }
    return true
}

@(private = "file", require_results)
pipe_read :: proc(
    self: ^Pipe,
    location: runtime.Source_Code_Location,
    allocator := context.allocator,
) -> (
    result: string,
    ok: bool,
) {
    INITIAL_BUF_SIZE :: 1024
    pipe_close_write(self, location) or_return
    total_bytes_read := 0
    buf := make([dynamic]u8, INITIAL_BUF_SIZE)
    defer delete(buf, loc = location)
    for {
        bytes_read, errno := linux.read(self.read, buf[total_bytes_read:])
        if bytes_read <= 0 {
            break
        }
        if errno != .NONE {
            log.errorf("Failed to read pipe: %s", libc.strerror(i32(errno)), location = location)
            return
        }
        total_bytes_read += bytes_read
        if total_bytes_read >= len(buf) {
            resize(&buf, 2 * len(buf))
        }
    }
    buf[total_bytes_read] = 0
    result = strings.clone_from_cstring(cstring(raw_data(buf)), allocator, location)
    ok = true
    return
}

@(private = "file", require_results)
fd_redirect :: proc(
    fd: linux.Fd,
    newfd: linux.Fd,
    location: runtime.Source_Code_Location,
) -> (
    ok: bool,
) {
    if _, errno := linux.dup2(fd, newfd); errno != .NONE {
        log.errorf(
            "Failed to redirect oldfd: %v, newfd: %v: %s",
            fd,
            newfd,
            libc.strerror(i32(errno)),
            location = location,
        )
        return false
    }
    return true
}

@(private = "file", require_results)
fd_close :: proc(fd: linux.Fd, location: runtime.Source_Code_Location) -> (ok: bool) {
    if errno := linux.close(fd); errno != .NONE {
        log.errorf("Failed to close fd %v: %s", fd, libc.strerror(i32(errno)), location = location)
        return false
    }
    return true
}

@(private = "file")
environ :: proc() -> [^]cstring #no_bounds_check {
    env: [^]cstring = &runtime.args__[len(runtime.args__)]
    assert(env[0] == nil)
    return &env[1]
}
