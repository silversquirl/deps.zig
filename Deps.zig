// Possible TODOs:
// - Parse source to ensure all dependencies are actually used

const std = @import("std");

b: *std.build.Builder,
deps: std.StringArrayHashMapUnmanaged(Dep) = .{},
dir: []const u8,
import_set: std.StringArrayHashMapUnmanaged(void) = .{},

const Deps = @This();
pub const Dep = struct {
    path: []const u8, // Absolute path to package main file
    deps: []const []const u8, // Dependencies of this package
};

pub fn init(b: *std.build.Builder) Deps {
    const dir = switch (std.builtin.os.tag) {
        .windows => b.fmt("{s}\\Temp\\deps-zig\\", .{std.os.getenv("LOCALAPPDATA").?}),
        .macos => b.fmt("{s}/Library/Caches/deps-zig/", .{std.os.getenv("HOME").?}),
        else => if (std.os.getenv("XDG_CACHE_HOME")) |cache|
            b.fmt("{s}/deps-zig/", .{cache})
        else
            b.fmt("{s}/.cache/deps-zig/", .{std.os.getenv("HOME").?}),
    };

    std.fs.makeDirAbsolute(dir) catch {};
    var dirh = std.fs.openDirAbsolute(dir, .{}) catch |err| {
        std.debug.print("Could not open packages dir '{}': {s}\n", .{ std.fmt.fmtSliceEscapeLower(dir), @errorName(err) });
        std.os.exit(1);
    };
    defer dirh.close();
    // Purposefully leak the file descriptor - it will be unlocked when the process exits
    _ = dirh.createFile(".lock", .{ .lock = .Exclusive, .lock_nonblocking = true }) catch |err| {
        std.debug.print("Failed to aqcuire package lock: {s}\n", .{@errorName(err)});
        std.os.exit(1);
    };

    return .{ .b = b, .dir = dir };
}

pub fn addTo(self: Deps, step: *std.build.LibExeObjStep) void {
    var it = self.deps.iterator();
    while (it.next()) |entry| {
        step.addPackage(self.createPkg(entry.key_ptr.*, entry.value_ptr.*));
    }
}
fn createPkg(self: Deps, name: []const u8, dep: Dep) std.build.Pkg {
    return .{
        .name = name,
        .path = .{ .path = dep.path },
        .dependencies = if (dep.deps.len == 0) null else blk: {
            const deps = self.b.allocator.alloc(std.build.Pkg, dep.deps.len) catch unreachable;
            var i: usize = 0;
            for (dep.deps) |dname| {
                if (self.deps.get(dname)) |ddep| {
                    deps[i] = self.createPkg(dname, ddep);
                    i += 1;
                }
                // If we don't have the dep, ignore it and let the compiler error
            }
            break :blk deps[0..i];
        },
    };
}

pub fn add(self: *Deps, url: []const u8, version: []const u8) void {
    const url_base = std.fs.path.basenamePosix(url);
    const name = trimPrefix(u8, trimSuffix(u8, url_base, ".git"), "zig-");
    const path = self.fetchPkg(name, url, version);

    const main_file = blk: {
        var dirh = std.fs.cwd().openDir(path, .{}) catch {
            std.debug.print("Failed to open package dir: {s}\n", .{path});
            std.os.exit(1);
        };
        for ([_][]const u8{
            self.b.fmt("{s}.zig", .{name}),
            "main.zig",
            self.b.fmt("src{c}{s}.zig", .{ std.fs.path.sep, name }),
            "src" ++ [_]u8{std.fs.path.sep} ++ "main.zig",
        }) |p| {
            if (dirh.access(p, .{})) |_| {
                dirh.close();
                break :blk p;
            } else |_| {}
        }
        dirh.close();

        std.debug.print("Could not find package entrypoint, attempted {s}.zig, main.zig, src{c}{[0]s}.zig and src{[1]c}main.zig\n", .{ name, std.fs.path.sep });
        std.os.exit(1);
    };
    const main_path = std.fs.path.join(self.b.allocator, &.{ path, main_file }) catch unreachable;

    const deps = self.parsePackageDeps(main_path) catch |err| switch (err) {
        error.InvalidSyntax => &[_][]const u8{},
        else => {
            std.debug.print("Failed to parse package dependencies for {s}: {s}\n", .{ main_file, @errorName(err) });
            std.os.exit(1);
        },
    };

    if (self.deps.fetchPut(self.b.allocator, name, .{ .path = main_path, .deps = deps }) catch unreachable) |_| {
        std.debug.print("Duplicate dependency '{s}'\n", .{std.fmt.fmtSliceEscapeLower(name)});
        std.os.exit(1);
    }
}

fn fetchPkg(self: Deps, name: []const u8, url: []const u8, version: []const u8) []const u8 {
    const path = self.b.allocator.alloc(u8, self.dir.len + url.len + 1 + version.len) catch unreachable;

    // Base dir (includes path sep)
    var i: usize = 0;
    std.debug.assert(self.dir[self.dir.len - 1] == std.fs.path.sep);
    std.mem.copy(u8, path[i..], self.dir);
    i += self.dir.len;

    // Encoded URL (/ replaced with : so it's a valid path)
    std.mem.copy(u8, path[i..], url);
    std.mem.replaceScalar(u8, path[i .. i + url.len], '/', ':');
    i += url.len;

    // Version separator
    path[i] = '@';
    i += 1;

    // Version
    std.mem.copy(u8, path[i..], version);
    i += version.len;
    std.debug.assert(i == path.len);

    // If we don't have the dep already, clone it
    std.fs.cwd().access(path, .{}) catch {
        self.exec(&.{
            "git",
            "clone",
            "--depth=1",
            "--no-single-branch",
            "--shallow-submodules",
            "--",
            url,
            path,
        }, null);
    };

    self.exec(&.{ "git", "fetch", "--all", "-Ppqt" }, path);
    // Check if there are changes - we don't want to clobber them
    if (self.execOk(&.{ "git", "diff", "--quiet", "HEAD" }, path)) {
        // Clean; check if version is a branch
        if (self.execOk(&.{
            "git",
            "show-ref",
            "--verify",
            "--",
            self.b.fmt("refs/heads/{s}", .{version}),
        }, path)) {
            // It is, so switch to it and pull
            self.exec(&.{ "git", "switch", "-q", "--", version }, path);
            self.exec(&.{ "git", "pull", "-q", "--ff-only" }, path);
        } else {
            // It isn't, check out detached
            self.exec(&.{ "git", "switch", "-dq", "--", version }, path);
        }
    } else {
        // Dirty; print a warning
        std.debug.print("WARNING: package {s} contains uncommitted changes, not attempting to update\n", .{name});
    }

    return path;
}

fn parsePackageDeps(self: *Deps, main_file: []const u8) ![]const []const u8 {
    defer self.import_set.clearRetainingCapacity();

    var npkg = try self.collectImports(std.fs.cwd(), main_file);
    const pkgs = try self.b.allocator.alloc([]const u8, npkg);
    for (self.import_set.keys()) |key| {
        if (isPkg(key)) {
            npkg -= 1;
            pkgs[npkg] = key;
        }
    }

    return pkgs;
}
fn collectImports(self: *Deps, dir: std.fs.Dir, import: []const u8) CollectImportsError!usize {
    const data = dir.readFileAlloc(self.b.allocator, import, 4 << 30) catch |err| switch (err) {
        error.FileTooBig => {
            // If you have a 4GiB source file, you have a problem
            // However, we probably shouldn't outright error in this situation, so instead we'll warn and skip this file
            std.debug.print("Could not parse exceptionally large source file '{s}', skipping\n", .{std.fmt.fmtSliceEscapeLower(import)});
            return 0;
        },
        else => |e| return e,
    };
    var subdir = try dir.openDir(std.fs.path.dirname(import) orelse ".", .{});
    defer subdir.close();

    var toks = std.zig.Tokenizer.init(data);
    var npkg: usize = 0;
    while (true) {
        const tok = toks.next();
        if (tok.tag == .eof) break;

        if (tok.tag == .builtin and std.mem.eql(u8, data[tok.loc.start..tok.loc.end], "@import")) {
            if (toks.next().tag != .l_paren) return error.InvalidSyntax;
            const name_tok = toks.next();
            if (name_tok.tag != .string_literal) return error.InvalidSyntax;
            if (toks.next().tag != .r_paren) return error.InvalidSyntax;

            const name = std.zig.string_literal.parseAlloc(
                self.b.allocator,
                data[name_tok.loc.start..name_tok.loc.end],
            ) catch |err| switch (err) {
                error.InvalidStringLiteral => return error.InvalidSyntax,
                else => |e| return e,
            };

            if (try self.import_set.fetchPut(self.b.allocator, name, {})) |_| {
                // Do nothing, the entry is already in the set
            } else if (isPkg(name)) {
                npkg += 1;
            } else if (std.mem.endsWith(u8, name, ".zig")) {
                npkg += try self.collectImports(subdir, name);
            }
        }
    }

    return npkg;
}
const CollectImportsError =
    std.fs.Dir.OpenError ||
    std.fs.File.OpenError ||
    std.fs.File.ReadError ||
    std.fs.File.SeekError ||
    std.mem.Allocator.Error ||
    error{InvalidSyntax};

fn isPkg(name: []const u8) bool {
    if (std.mem.endsWith(u8, name, ".zig")) return false;
    if (std.mem.eql(u8, name, "std")) return false;
    if (std.mem.eql(u8, name, "root")) return false;
    return true;
}

fn trimPrefix(comptime T: type, haystack: []const T, needle: []const T) []const T {
    if (std.mem.startsWith(T, haystack, needle)) {
        return haystack[needle.len..];
    } else {
        return haystack;
    }
}
fn trimSuffix(comptime T: type, haystack: []const T, needle: []const T) []const T {
    if (std.mem.endsWith(T, haystack, needle)) {
        return haystack[0 .. haystack.len - needle.len];
    } else {
        return haystack;
    }
}

fn exec(self: Deps, argv: []const []const u8, cwd: ?[]const u8) void {
    if (!self.execInternal(argv, cwd, .Inherit)) {
        std.debug.print("Command failed: {s}", .{argv[0]});
        for (argv[1..]) |arg| {
            std.debug.print(" {s}", .{arg});
        }
        std.debug.print("\n", .{});
        std.os.exit(1);
    }
}

fn execOk(self: Deps, argv: []const []const u8, cwd: ?[]const u8) bool {
    return self.execInternal(argv, cwd, .Ignore);
}

fn execInternal(self: Deps, argv: []const []const u8, cwd: ?[]const u8, io: std.ChildProcess.StdIo) bool {
    const child = std.ChildProcess.init(argv, self.b.allocator) catch unreachable;
    defer child.deinit();

    child.cwd = cwd;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = io;
    child.stderr_behavior = io;
    child.env_map = self.b.env_map;

    const term = child.spawnAndWait() catch |err| {
        std.debug.print("Unable to spawn {s}: {s}\n", .{ argv[0], @errorName(err) });
        return false;
    };
    switch (term) {
        .Exited => |code| if (code != 0) {
            return false;
        },
        .Signal, .Stopped, .Unknown => {
            return false;
        },
    }
    return true;
}
