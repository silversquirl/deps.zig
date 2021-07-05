# Deps.zig

Deps.zig is a dependency manager for Zig. It is designed for simplicity from both an implementation
and usability standpoint. The API is similar to the other APIs used in `build.zig`, and is implemented
in around 300 lines of code.

It is configured solely through `build.zig`, and automatically builds dependency trees without any extra
metadata, however it requires every package in the tree to be registered manually. This means you may need
to specify packages you don't directly depend on, but allows for more flexibility as you can swap out
compatible implementations as you see fit.

## Usage

Deps.zig is a standalone Zig file that is designed to be copied into your project.
It will install packages into a system-specific directory:

- *nix: `$XDG_CACHE_HOME/deps-zig/`
- Windows: `%LOCALAPPDATA%\Temp\deps-zig\`
- macOS: `~/Library/Caches/deps-zig/`

To use Deps.zig in your `build.zig`, simply add code like the following, or look in the `example`
directory in this repo for a more complete example.

```zig
// Create a new dependency list
var deps = @import("Deps.zig").init(b);
// Add a package, with a "version" of `main`, meaning it will use the latest commit on the `main` branch
deps.add("https://github.com/vktec/zig-uuid", "main");
// Add all registered packages to the executable step
deps.addTo(exe);
```
