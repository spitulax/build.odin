package tests

import b ".."
import "core:strings"
import "utils"

options_start :: proc() -> (ok: bool) {
    arch := b.option_get("arch", b.Arch_Type) or_return
    optimization := b.option_get("optimization", i32) or_return
    features_str := b.option_get("features", string) or_return
    features := strings.split(features_str, ",")
    defer delete(features)

    utils.expect(arch, b.Arch_Type.amd64) or_return
    utils.expect(optimization, 3) or_return
    utils.expect(features, []string{"foo", "bar", "baz"}) or_return

    return true
}

main :: proc() {
    b.option_add("arch", b.Arch_Type, "The target architecture")
    b.option_add("optimization", i32, 2, "The optimization level")
    b.option_add("features", string, "Extra features to enable (separated by `,`)")
    b.start(options_start)
}

