const std = @import("std");

b: *std.build.Builder,
deps: std.ArrayListUnmanaged(Dep) = .{},

const Deps = @This();
pub const Dep = struct {
    name: []const u8, // Name of package
    path: []const u8, // Path to package main file, relative to pwd
};

pub fn init(b: *std.build.Builder) Deps {
    return .{ .b = b };
}

pub fn add(self: *Deps, url: []const u8, version: []const u8) void {
    const base_dir = std.fs.path.dirname(@src().file) orelse ".";
    const url_base = std.fs.path.basenamePosix(url);
    const name = trimPrefix(u8, trimSuffix(u8, url_base, ".git"), "zig-");
    const dir = std.fs.path.join(self.b.allocator, &.{ base_dir, name }) catch unreachable;

    std.fs.cwd().access(dir, .{}) catch {
        // Check if we're in a git repo
        if (self.execOk(&.{ "git", "rev-parse", "--is-inside-work-tree" }, base_dir)) {
            // We are, so use submodules
            self.exec(&.{
                "git",
                "submodule",
                "add",
                "--depth=1",
                "--",
                url,
                name,
            }, base_dir);
        } else {
            // We aren't, so clone
            self.exec(&.{
                "git",
                "clone",
                "--depth=1",
                "--no-single-branch",
                "--shallow-submodules",
                "--",
                url,
                name,
            }, base_dir);
        }
    };

    self.exec(&.{ "git", "fetch", "--all", "-Ppqt" }, dir);
    // Check if there are changes - we don't want to clobber them
    if (self.execOk(&.{ "git", "diff", "--quiet", "HEAD" }, dir)) {
        // Clean; check if version is a branch
        if (self.execOk(&.{
            "git",
            "show-ref",
            "--verify",
            "--",
            self.b.fmt("refs/heads/{s}", .{version}),
        }, dir)) {
            // It is, so switch to it and pull
            self.exec(&.{ "git", "switch", "-q", "--", version }, dir);
            self.exec(&.{ "git", "pull", "-q", "--ff-only" }, dir);
        } else {
            // It isn't, check out detached
            self.exec(&.{ "git", "switch", "-dq", "--", version }, dir);
        }
    } else {
        // Dirty; print a warning
        std.debug.print("WARNING: package {s} contains uncommitted changes, not attempting to update\n", .{name});
    }

    const main_file = blk: {
        var dirh = std.fs.cwd().openDir(dir, .{}) catch {
            std.debug.print("Failed to open package dir: {s}\n", .{dir});
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
    const path = std.fs.path.join(self.b.allocator, &.{ dir, main_file }) catch unreachable;

    self.deps.append(self.b.allocator, .{
        .name = name,
        .path = path,
    }) catch unreachable;
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

pub fn addTo(self: Deps, step: *std.build.LibExeObjStep) void {
    for (self.deps.items) |dep| {
        step.addPackagePath(dep.name, dep.path);
    }
}
