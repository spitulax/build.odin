<h1 align="center">build.odin</h1>

## Quick Start

1. Clone the repository to your project or add it as a submodule.

```console
$ git clone https://github.com/spitulax/build.odin --depth 1 shared/build.odin
```

2. Create a build script.

`build.odin`:

```odin
package build

import b "shared/build.odin"
import "core:log"

start :: proc() -> (ok: bool) {
    log.info("Hello, World!")
    return true
}

main :: proc() {
    b.start(start)
}
```

3. Run the build script.

```console
$ odin build build.odin -file && ./build
```
