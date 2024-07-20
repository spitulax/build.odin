package tests

import b "../build_odin"
import "core:log"
import "utils"

init_stage_proc :: proc(self: ^b.Stage, userdata: rawptr) -> (ok: bool) {
    log.infof("From `%s`", b.stage_name(self^))
    for dep in self.dependencies {
        log.infof("`%s` %v", b.stage_name(dep^), dep.status)
        utils.expect(dep.status, b.Stage_Status.Success) or_return
    }
    return true
}

ok_stage_proc :: proc(self: ^b.Stage, userdata: rawptr) -> (ok: bool) {
    log.infof("From `%s`", b.stage_name(self^))
    data := cast(^int)userdata
    data^ += 1
    for dep in self.dependencies {
        log.infof("`%s` %v", b.stage_name(dep^), dep.status)
        utils.expect(dep.status, b.Stage_Status.Failed) or_return
    }
    return true
}

not_ok_stage_proc :: proc(self: ^b.Stage, userdata: rawptr) -> (ok: bool) {
    log.infof("From `%s`", b.stage_name(self^))
    data := cast(^int)userdata
    data^ += 1
    return false
}

stages_start :: proc() -> (ok: bool) {
    userdata := 0

    root_stage := b.stage_make(init_stage_proc, "root")
    defer b.destroy_stages(&root_stage)

    ok_stage := b.stage_make(ok_stage_proc, "ok", userdata = rawptr(&userdata))
    b.stage_add_dependency(&root_stage, &ok_stage)

    not_ok_stage := b.stage_make(
        not_ok_stage_proc,
        "not_ok",
        userdata = rawptr(&userdata),
        require = false,
    )
    b.stage_add_dependency(&ok_stage, &not_ok_stage)

    b.run_stages(&root_stage) or_return

    utils.expect(2, userdata) or_return
    return true
}

main :: proc() {
    b.start(stages_start)
}

