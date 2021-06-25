# Deps.zig

Deps.zig is a dependency manager for Zig. It does not work like a typical package manager,
but instead provides a simple way to interact with git submodules from a `build.zig`.
It is designed for simplicity from both an implementation and usability standpoint. The API
is similar to the other APIs used in `build.zig`, and is implemented in under 150 lines of code.

## Usage

Deps.zig is a ~150 line, standalone Zig file that is designed to be copied into your project.
Since it will install dependencies into the same directory it is located in, it is recommended
to place it in a directory named `deps`.

Not only is this a simple and descriptive name for a directory that holds dependencies, it is
also one that is whitelisted by GitHub's [Linguist], meaning code placed within it will not be
counted in your repo's language breakdown.

To use Deps.zig in your `build.zig`, simply add code like the following, or look in the `example`
directory in this repo for a more complete example.

```zig
// Create a new dependency list
var deps = @import("deps/Deps.zig").init(b);
// Add a package, with a "version" of `main`, meaning it will use the latest commit on the `main` branch
deps.add("https://github.com/vktec/zig-uuid", "main");
// Add all registered packages to the executable step
deps.addTo(exe);
```

[Linguist]: https://github.com/github/linguist
