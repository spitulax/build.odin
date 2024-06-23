package build

import "base:runtime"
import "core:c/libc"
import "core:fmt"
import "core:log"
import "core:strings"
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

Exit :: distinct u32
Signal :: distinct linux.Signal
Process_Exit :: union {
    Exit,
    Signal,
}

Process :: struct {
    pid:            linux.Pid,
    execution_time: time.Time,
    stdout_pipe:    Maybe(Pipe),
    stderr_pipe:    Maybe(Pipe),
}
process_wait :: proc(
    self: Process,
    allocator := context.allocator,
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
        result.duration = time.since(self.execution_time)

        if linux.WIFEXITED(status) && linux.WEXITSTATUS(status) == EXIT_BEFORE_EXEC {
            log.errorf(
                "Process %v did not execute the command successfully",
                self.pid,
                location = location,
            )
            return
        }

        if linux.WIFSIGNALED(status) || linux.WIFEXITED(status) {
            stdout_pipe, stdout_pipe_ok := self.stdout_pipe.?
            stderr_pipe, stderr_pipe_ok := self.stderr_pipe.?
            if stdout_pipe_ok || stderr_pipe_ok {
                assert(
                    stderr_pipe_ok == stdout_pipe_ok,
                    "stdout and stderr pipe isn't equally initialized",
                )
                result.stdout = pipe_read(&stdout_pipe, location, allocator) or_return
                result.stderr = pipe_read(&stderr_pipe, location, allocator) or_return
                pipe_close_read(&stdout_pipe, location) or_return
                pipe_close_read(&stderr_pipe, location) or_return
            }
        }

        if linux.WIFSIGNALED(status) {
            result.exit = Signal(linux.WTERMSIG(status))
            ok = true
            return
        }

        if linux.WIFEXITED(status) {
            exit_code := linux.WEXITSTATUS(status)
            result.exit = (exit_code == 0) ? nil : Exit(exit_code)
            ok = true
            return
        }
    }
}
process_wait_many :: proc(
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

Process_Result :: struct {
    exit:     Process_Exit, // nil on success
    duration: time.Duration,
    stdout:   string, // both are empty if run_cmd_* is not capturing
    stderr:   string,
}
process_result_destroy :: proc(self: ^Process_Result, location := #caller_location) {
    delete(self.stdout, loc = location)
    delete(self.stderr, loc = location)
}
process_result_destroy_many :: proc(selves: []Process_Result, location := #caller_location) {
    for &result in selves {
        process_result_destroy(&result, location)
    }
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
    if len(cmd) < 1 {
        log.error("Command is empty", location = location)
        return
    }

    stdout_pipe, stderr_pipe: Pipe
    dev_null, dev_null_errno := linux.open("/dev/null", {.RDWR, .CREAT}, {.IWUSR, .IWGRP, .IWOTH})
    assert(dev_null_errno == .NONE, "could not open /dev/null")
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
            linux.exit(EXIT_BEFORE_EXEC)
        }

        // TODO: fix logging from child processes. Maybe using the global variable solution
        // explained in the definition of `EXIT_BEFORE_EXEC`?

        // because of .Silent and .Capture shenanigans, any log here is written into file instead
        //logger := context.logger
        //if option == .Share || option == .Capture {
        //    logfile, errno := os.open(
        //        "build_odin-log.txt",
        //        os.O_RDWR | os.O_CREATE | os.O_APPEND,
        //        0o644,
        //    )
        //    if errno != os.ERROR_NONE {
        //        log.errorf(
        //            "Failed to create log file: %s",
        //            libc.strerror(i32(errno)),
        //            location = location,
        //        )
        //        fail()
        //    }
        //    logger = log.create_file_logger(logfile)
        //}
        //context.logger = logger

        switch option {
        case .Share:
            if !fd_close(dev_null, location) {fail()}
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

        if errno := linux.execve(argv[0], raw_data(argv), environ()); errno != .NONE {
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

    fd_close(dev_null, location) or_return

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

