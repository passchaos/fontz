//! Minimal pure-Zig fontconfig configuration reader.
//!
//! This is intentionally a subset of fontconfig's XML configuration: it reads
//! `<dir>`, `<include>` and `<alias>` rules, including XDG/`~` directory
//! prefixes. Font matching, substitution and cache handling remain in
//! `metadata/index.zig`.

const std = @import("std");
const family_mod = @import("../family.zig");
const env = @import("../env.zig");

pub const Alias = struct {
    generic: family_mod.GenericFamily,
    families: []const []const u8,
};

pub const Config = struct {
    arena: std.heap.ArenaAllocator,
    dirs: []const []const u8,
    aliases: []const Alias,

    pub fn deinit(self: *Config) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub fn empty(base_allocator: std.mem.Allocator) Config {
    return .{
        .arena = std.heap.ArenaAllocator.init(base_allocator),
        .dirs = &.{},
        .aliases = &.{},
    };
}

const max_config_bytes = 4 * 1024 * 1024;
const max_include_depth = 16;

/// Load fontconfig configuration files. Missing files are ignored; a missing
/// or empty configuration yields empty `dirs` and `aliases`.
pub fn load(io: std.Io, base_allocator: std.mem.Allocator) !Config {
    var arena = std.heap.ArenaAllocator.init(base_allocator);
    errdefer arena.deinit();
    var builder = Builder.init(io, arena.allocator());

    if (env.get(arena.allocator(), "FONTCONFIG_FILE")) |path| {
        defer arena.allocator().free(path);
        try builder.parseFile(path, 0);
    } else {
        if (env.get(arena.allocator(), "FONTCONFIG_PATH")) |path| {
            defer arena.allocator().free(path);
            try builder.parseFile(try std.fs.path.join(arena.allocator(), &.{ path, "fonts.conf" }), 0);
        } else {
            if (env.get(arena.allocator(), "XDG_CONFIG_HOME")) |xdg| {
                defer arena.allocator().free(xdg);
                try builder.parseFile(try std.fs.path.join(arena.allocator(), &.{ xdg, "fontconfig", "fonts.conf" }), 0);
            } else if (env.get(arena.allocator(), "HOME")) |home| {
                defer arena.allocator().free(home);
                try builder.parseFile(try std.fs.path.join(arena.allocator(), &.{ home, ".config", "fontconfig", "fonts.conf" }), 0);
            }
            try builder.parseFile("/etc/fonts/local.conf", 0);
            try builder.parseFile("/etc/fonts/fonts.conf", 0);
        }
    }

    return builder.finishWithArena(arena);
}

const Builder = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    dirs: std.ArrayList([]const u8) = .empty,
    aliases: std.ArrayList(AliasBuilder) = .empty,
    visited: std.StringHashMapUnmanaged(void) = .empty,

    fn init(io: std.Io, allocator: std.mem.Allocator) Builder {
        return .{ .io = io, .allocator = allocator };
    }

    fn finish(self: *Builder) Config {
        var aliases: std.ArrayList(Alias) = .empty;
        for (self.aliases.items) |*builder| {
            const families = builder.families.toOwnedSlice(self.allocator) catch &.{};
            aliases.append(self.allocator, .{
                .generic = builder.generic,
                .families = families,
            }) catch {};
        }
        const owned_aliases = aliases.toOwnedSlice(self.allocator) catch &.{};
        const owned_dirs = self.dirs.toOwnedSlice(self.allocator) catch &.{};
        return .{
            .arena = undefined,
            .dirs = owned_dirs,
            .aliases = owned_aliases,
        };
    }

    fn finishWithArena(self: *Builder, arena: std.heap.ArenaAllocator) Config {
        var config = self.finish();
        config.arena = arena;
        return config;
    }

    fn parseFile(self: *Builder, path: []const u8, depth: usize) anyerror!void {
        if (depth > max_include_depth) return;
        const absolute = if (std.fs.path.isAbsolute(path))
            try self.allocator.dupe(u8, path)
        else
            try std.fs.path.join(self.allocator, &.{ ".", path });
        if (self.visited.contains(absolute)) return;
        try self.visited.put(self.allocator, absolute, {});

        const directory_open = if (std.fs.path.isAbsolute(absolute))
            std.Io.Dir.openDirAbsolute(self.io, absolute, .{ .iterate = true })
        else
            std.Io.Dir.cwd().openDir(self.io, absolute, .{ .iterate = true });
        if (directory_open) |dir_value| {
            var dir = dir_value;
            defer dir.close(self.io);
            var iterator = dir.iterate();
            var names: std.ArrayList([]const u8) = .empty;
            while (iterator.next(self.io) catch null) |entry| {
                if (entry.kind != .file and entry.kind != .sym_link) continue;
                if (!std.mem.endsWith(u8, entry.name, ".conf")) continue;
                try names.append(self.allocator, try self.allocator.dupe(u8, entry.name));
            }
            std.mem.sort([]const u8, names.items, {}, lessThanString);
            for (names.items) |name| {
                const child = try std.fs.path.join(self.allocator, &.{ absolute, name });
                try self.parseFile(child, depth + 1);
            }
            return;
        } else |_| {}

        var file = if (std.fs.path.isAbsolute(absolute))
            std.Io.Dir.openFileAbsolute(self.io, absolute, .{}) catch return
        else
            std.Io.Dir.cwd().openFile(self.io, absolute, .{}) catch return;
        defer file.close(self.io);
        const stat = file.stat(self.io) catch return;
        const size = std.math.cast(usize, stat.size) orelse return;
        if (size == 0 or size > max_config_bytes) return;
        const bytes = try self.allocator.alloc(u8, size);
        const read = file.readPositionalAll(self.io, bytes, 0) catch return;
        if (read != size) return;
        const base_dir = std.fs.path.dirname(absolute) orelse ".";
        var parser = Parser{
            .bytes = bytes,
            .builder = self,
            .base_dir = base_dir,
            .depth = depth,
        };
        try parser.run();
    }
};

const AliasBuilder = struct {
    generic: family_mod.GenericFamily,
    families: std.ArrayList([]const u8) = .empty,
};

const AliasSection = enum { none, prefer, accept, default };

const CaptureKind = enum { dir, include, family };

const Capture = struct {
    kind: CaptureKind,
    prefix: ?[]const u8 = null,
    ignore_missing: bool = false,
    buffer: std.ArrayList(u8) = .empty,
};

const Attributes = struct {
    prefix: ?[]const u8 = null,
    ignore_missing: bool = false,
};

const Parser = struct {
    bytes: []const u8,
    builder: *Builder,
    base_dir: []const u8,
    depth: usize,
    index: usize = 0,
    capture: ?Capture = null,
    alias_active: bool = false,
    alias_target: ?[]const u8 = null,
    alias_section: AliasSection = .none,
    alias_families: std.ArrayList([]const u8) = .empty,

    fn run(self: *Parser) !void {
        while (self.index < self.bytes.len) {
            const next_tag = std.mem.indexOfScalarPos(u8, self.bytes, self.index, '<') orelse {
                try self.appendText(self.bytes[self.index..]);
                break;
            };
            if (next_tag > self.index) try self.appendText(self.bytes[self.index..next_tag]);
            self.index = next_tag;
            if (std.mem.startsWith(u8, self.bytes[self.index..], "<!--")) {
                const end = std.mem.indexOfPos(u8, self.bytes, self.index + 4, "-->") orelse break;
                self.index = end + 3;
                continue;
            }
            if (std.mem.startsWith(u8, self.bytes[self.index..], "<?")) {
                const end = std.mem.indexOfPos(u8, self.bytes, self.index + 2, "?>") orelse break;
                self.index = end + 2;
                continue;
            }
            if (std.mem.startsWith(u8, self.bytes[self.index..], "<!")) {
                const end = std.mem.indexOfScalarPos(u8, self.bytes, self.index + 2, '>') orelse break;
                self.index = end + 1;
                continue;
            }
            if (std.mem.startsWith(u8, self.bytes[self.index..], "</")) {
                self.index += 2;
                const name_start = self.index;
                while (self.index < self.bytes.len and self.bytes[self.index] != '>') : (self.index += 1) {}
                const name = std.mem.trim(u8, self.bytes[name_start..self.index], " \t\r\n");
                if (self.index < self.bytes.len) self.index += 1;
                try self.handleEndTag(stripNamespace(name));
                continue;
            }
            self.index += 1;
            const name_start = self.index;
            while (self.index < self.bytes.len and
                self.bytes[self.index] != '>' and
                self.bytes[self.index] != '/' and
                !std.ascii.isWhitespace(self.bytes[self.index])) : (self.index += 1)
            {}
            const name = self.bytes[name_start..self.index];
            var attributes = Attributes{};
            var self_closing = false;
            while (self.index < self.bytes.len) {
                const byte = self.bytes[self.index];
                if (byte == '>') {
                    self.index += 1;
                    break;
                }
                if (byte == '/') {
                    self_closing = true;
                    self.index += 1;
                    continue;
                }
                if (std.ascii.isWhitespace(byte)) {
                    self.index += 1;
                    continue;
                }
                self.parseAttribute(&attributes);
            }
            try self.handleStartTag(stripNamespace(name), attributes, self_closing);
        }
        try self.finishCapture();
        if (self.alias_active) try self.finishAlias();
    }

    fn parseAttribute(self: *Parser, attributes: *Attributes) void {
        const name_start = self.index;
        while (self.index < self.bytes.len and
            self.bytes[self.index] != '=' and
            !std.ascii.isWhitespace(self.bytes[self.index]) and
            self.bytes[self.index] != '>' and
            self.bytes[self.index] != '/') : (self.index += 1)
        {}
        const name = self.bytes[name_start..self.index];
        while (self.index < self.bytes.len and std.ascii.isWhitespace(self.bytes[self.index])) : (self.index += 1) {}
        if (self.index >= self.bytes.len or self.bytes[self.index] != '=') return;
        self.index += 1;
        while (self.index < self.bytes.len and std.ascii.isWhitespace(self.bytes[self.index])) : (self.index += 1) {}
        if (self.index >= self.bytes.len) return;
        const quote = self.bytes[self.index];
        if (quote != '"' and quote != '\'') return;
        self.index += 1;
        const value_start = self.index;
        while (self.index < self.bytes.len and self.bytes[self.index] != quote) : (self.index += 1) {}
        const value = self.bytes[value_start..self.index];
        if (self.index < self.bytes.len) self.index += 1;
        if (std.ascii.eqlIgnoreCase(name, "prefix")) attributes.prefix = value;
        if (std.ascii.eqlIgnoreCase(name, "ignore_missing")) {
            attributes.ignore_missing = std.ascii.eqlIgnoreCase(value, "yes") or
                std.ascii.eqlIgnoreCase(value, "true");
        }
    }

    fn handleStartTag(
        self: *Parser,
        name: []const u8,
        attributes: Attributes,
        self_closing: bool,
    ) !void {
        if (std.mem.eql(u8, name, "include")) {
            if (self.capture != null) try self.finishCapture();
            self.capture = .{ .kind = .include, .ignore_missing = attributes.ignore_missing };
            if (self_closing) try self.finishCapture();
            return;
        }
        if (std.mem.eql(u8, name, "dir")) {
            if (self.capture != null) try self.finishCapture();
            self.capture = .{ .kind = .dir, .prefix = attributes.prefix };
            if (self_closing) try self.finishCapture();
            return;
        }
        if (std.mem.eql(u8, name, "alias")) {
            self.alias_active = true;
            self.alias_target = null;
            self.alias_section = .none;
            self.alias_families.clearRetainingCapacity();
            return;
        }
        if (self.alias_active) {
            if (std.mem.eql(u8, name, "prefer")) {
                self.alias_section = .prefer;
                return;
            }
            if (std.mem.eql(u8, name, "accept")) {
                self.alias_section = .accept;
                return;
            }
            if (std.mem.eql(u8, name, "default")) {
                self.alias_section = .default;
                return;
            }
            if (std.mem.eql(u8, name, "family")) {
                if (self.capture != null) try self.finishCapture();
                self.capture = .{ .kind = .family };
                if (self_closing) try self.finishCapture();
                return;
            }
        }
    }

    fn handleEndTag(self: *Parser, name: []const u8) !void {
        if (std.mem.eql(u8, name, "include") or std.mem.eql(u8, name, "dir") or
            std.mem.eql(u8, name, "family"))
        {
            try self.finishCapture();
            return;
        }
        if (std.mem.eql(u8, name, "prefer") or std.mem.eql(u8, name, "accept") or
            std.mem.eql(u8, name, "default"))
        {
            self.alias_section = .none;
            return;
        }
        if (std.mem.eql(u8, name, "alias")) {
            try self.finishAlias();
        }
    }

    fn appendText(self: *Parser, text: []const u8) !void {
        if (self.capture) |*capture| {
            try decodeEntities(&capture.buffer, self.builder.allocator, text);
        }
    }

    fn finishCapture(self: *Parser) !void {
        var capture = self.capture orelse return;
        self.capture = null;
        const trimmed = std.mem.trim(u8, capture.buffer.items, " \t\r\n");
        defer capture.buffer.deinit(self.builder.allocator);
        if (trimmed.len == 0) return;
        // The arena can reclaim the buffer on deinit, so keep a stable copy.
        const text = try self.builder.allocator.dupe(u8, trimmed);
        switch (capture.kind) {
            .include => {
                const path = try self.resolveInclude(text);
                try self.builder.parseFile(path, self.depth + 1);
            },
            .dir => {
                const path = try self.resolveDir(text, capture.prefix);
                if (path.len != 0 and !containsString(self.builder.dirs.items, path)) {
                    try self.builder.dirs.append(self.builder.allocator, path);
                }
            },
            .family => {
                if (self.alias_target == null) {
                    self.alias_target = text;
                } else {
                    if (!containsString(self.alias_families.items, text)) {
                        try self.alias_families.append(self.builder.allocator, text);
                    }
                }
            },
        }
    }

    fn finishAlias(self: *Parser) !void {
        defer {
            self.alias_active = false;
            self.alias_target = null;
            self.alias_section = .none;
            self.alias_families.clearRetainingCapacity();
        }
        const target = self.alias_target orelse return;
        const generic = family_mod.genericFamily(target) orelse return;
        if (self.alias_families.items.len == 0) return;
        for (self.builder.aliases.items) |*existing| {
            if (existing.generic != generic) continue;
            for (self.alias_families.items) |family| {
                if (!containsString(existing.families.items, family)) {
                    try existing.families.append(self.builder.allocator, family);
                }
            }
            return;
        }
        var builder = AliasBuilder{ .generic = generic };
        for (self.alias_families.items) |family| {
            try builder.families.append(self.builder.allocator, family);
        }
        try self.builder.aliases.append(self.builder.allocator, builder);
    }

    fn resolveInclude(self: *Parser, text: []const u8) ![]const u8 {
        if (std.fs.path.isAbsolute(text)) return text;
        return try std.fs.path.join(self.builder.allocator, &.{ self.base_dir, text });
    }

    fn resolveDir(self: *Parser, text: []const u8, prefix: ?[]const u8) ![]const u8 {
        if (prefix) |value| {
            if (std.ascii.eqlIgnoreCase(value, "xdg")) {
                const base = if (env.get(self.builder.allocator, "XDG_DATA_HOME")) |xdg|
                    xdg
                else if (env.get(self.builder.allocator, "HOME")) |home|
                    try std.fs.path.join(self.builder.allocator, &.{ home, ".local", "share" })
                else
                    "";
                return try std.fs.path.join(self.builder.allocator, &.{ base, text });
            }
            if (std.ascii.eqlIgnoreCase(value, "relative")) {
                return try std.fs.path.join(self.builder.allocator, &.{ self.base_dir, text });
            }
        }
        if (text.len >= 1 and text[0] == '~') {
            if (env.get(self.builder.allocator, "HOME")) |home| {
                const rest = std.mem.trimStart(u8, text[1..], "/");
                return try std.fs.path.join(self.builder.allocator, &.{ home, rest });
            }
        }
        if (std.fs.path.isAbsolute(text)) return text;
        return try std.fs.path.join(self.builder.allocator, &.{ self.base_dir, text });
    }
};

fn stripNamespace(name: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, name, ':')) |index| return name[index + 1 ..];
    return name;
}

fn lessThanString(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn containsString(items: []const []const u8, value: []const u8) bool {
    for (items) |item| {
        if (std.mem.eql(u8, item, value)) return true;
    }
    return false;
}

fn decodeEntities(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    text: []const u8,
) !void {
    var index: usize = 0;
    while (index < text.len) {
        const start = std.mem.indexOfScalarPos(u8, text, index, '&') orelse {
            try out.appendSlice(allocator, text[index..]);
            return;
        };
        try out.appendSlice(allocator, text[index..start]);
        const end = std.mem.indexOfScalarPos(u8, text, start + 1, ';') orelse {
            try out.appendSlice(allocator, text[start..]);
            return;
        };
        const entity = text[start + 1 .. end];
        if (std.mem.eql(u8, entity, "amp")) {
            try out.append(allocator, '&');
        } else if (std.mem.eql(u8, entity, "lt")) {
            try out.append(allocator, '<');
        } else if (std.mem.eql(u8, entity, "gt")) {
            try out.append(allocator, '>');
        } else if (std.mem.eql(u8, entity, "quot")) {
            try out.append(allocator, '"');
        } else if (std.mem.eql(u8, entity, "apos")) {
            try out.append(allocator, '\'');
        } else if (entity.len > 1 and entity[0] == '#') {
            const codepoint = if (entity.len > 2 and (entity[1] == 'x' or entity[1] == 'X'))
                std.fmt.parseInt(u21, entity[2..], 16) catch 0
            else
                std.fmt.parseInt(u21, entity[1..], 10) catch 0;
            if (codepoint != 0) {
                var buffer: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(codepoint, &buffer) catch 0;
                if (len != 0) try out.appendSlice(allocator, buffer[0..len]);
            }
        } else {
            try out.appendSlice(allocator, text[start .. end + 1]);
        }
        index = end + 1;
    }
}

fn parseForTest(allocator: std.mem.Allocator, bytes: []const u8, base_dir: []const u8) !Config {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    var builder = Builder.init(std.testing.io, arena.allocator());
    var parser = Parser{
        .bytes = bytes,
        .builder = &builder,
        .base_dir = base_dir,
        .depth = 0,
    };
    try parser.run();
    var config = builder.finish();
    config.arena = arena;
    return config;
}

test "fontconfig parser reads dirs, aliases and entities" {
    const source =
        \\<?xml version="1.0"?>
        \\<fontconfig>
        \\  <!-- comment -->
        \\  <dir>/usr/share/fonts</dir>
        \\  <dir>~/.local/share/fonts</dir>
        \\  <alias>
        \\    <family>sans-serif</family>
        \\    <prefer><family>Noto Sans</family></prefer>
        \\    <accept><family>DejaVu Sans</family></accept>
        \\  </alias>
        \\</fontconfig>
    ;
    var config = try parseForTest(std.testing.allocator, source, "/tmp");
    defer config.deinit();
    try std.testing.expect(config.dirs.len >= 2);
    try std.testing.expectEqualStrings("/usr/share/fonts", config.dirs[0]);
    try std.testing.expectEqual(@as(usize, 1), config.aliases.len);
    try std.testing.expectEqual(family_mod.GenericFamily.sans_serif, config.aliases[0].generic);
    try std.testing.expectEqualStrings("Noto Sans", config.aliases[0].families[0]);
    try std.testing.expectEqualStrings("DejaVu Sans", config.aliases[0].families[1]);
}

test "fontconfig parser resolves relative includes" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{
        .sub_path = "included.conf",
        .data = "<fontconfig><dir>/opt/fonts</dir></fontconfig>",
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "fonts.conf",
        .data = "<fontconfig><include>included.conf</include></fontconfig>",
    });
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &path_buffer);
    const main_path = try std.fs.path.join(std.testing.allocator, &.{ path_buffer[0..root_len], "fonts.conf" });
    defer std.testing.allocator.free(main_path);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var builder = Builder.init(io, arena.allocator());
    try builder.parseFile(main_path, 0);
    var config = builder.finish();
    config.arena = arena;
    try std.testing.expect(config.dirs.len == 1);
    try std.testing.expectEqualStrings("/opt/fonts", config.dirs[0]);
}
