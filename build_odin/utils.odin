//+private
package build_lib

import "core:fmt"
import "core:strings"

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

