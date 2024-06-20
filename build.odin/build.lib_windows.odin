package build

Process :: struct {}

process_wait :: proc(
    self: Process,
    allocator := context.allocator,
    location := #caller_location,
) -> (
    result: Process_Result,
    ok: bool,
) {
    unimplemented()
}

process_wait_many :: proc(
    selves: []Process,
    allocator := context.allocator,
    location := #caller_location,
) -> (
    results: []Process_Result,
    ok: bool,
) {
    unimplemented()
}

Process_Result :: struct {}
process_result_destroy :: proc(self: ^Process_Result) {
    unimplemented()
}
process_result_destroy_many :: proc(selves: []Process_Result) {
    unimplemented()
}

Run_Cmd_Option :: enum {}

run_cmd_async :: proc(
    cmd: []string,
    option: Run_Cmd_Option = .Share,
    location := #caller_location,
) -> (
    process: Process,
    ok: bool,
) {
    unimplemented()
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
    unimplemented()
}

