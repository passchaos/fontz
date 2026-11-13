const builtin = @import("builtin");
const Role = @import("types.zig").Role;

pub fn forRole(role: Role) []const []const u8 {
    return switch (role) {
        .ui => ui(),
        .monospace => monospace(),
        .cjk => cjk(),
        .emoji => emoji(),
        .symbol => symbol(),
    };
}

pub fn ui() []const []const u8 {
    return switch (builtin.target.os.tag) {
        .macos => &.{
            "/System/Library/Fonts/SFNS.ttf",
            "/System/Library/Fonts/HelveticaNeue.ttc",
            "/System/Library/Fonts/LucidaGrande.ttc",
            "/System/Library/Fonts/Supplemental/Arial.ttf",
            "/System/Library/Fonts/SFNSMono.ttf",
        },
        .windows => &.{
            "C:\\Windows\\Fonts\\segoeui.ttf",
            "C:\\Windows\\Fonts\\arial.ttf",
        },
        else => &.{
            "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
            "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
            "/usr/share/fonts/noto/NotoSans-Regular.ttf",
        },
    };
}

pub fn monospace() []const []const u8 {
    return switch (builtin.target.os.tag) {
        .macos => &.{
            "/System/Library/Fonts/SFNSMono.ttf",
            "/System/Library/Fonts/Menlo.ttc",
            "/System/Library/Fonts/Monaco.ttf",
        },
        .windows => &.{
            "C:\\Windows\\Fonts\\CascadiaMono.ttf",
            "C:\\Windows\\Fonts\\consola.ttf",
            "C:\\Windows\\Fonts\\lucon.ttf",
        },
        else => &.{
            "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
            "/usr/share/fonts/truetype/liberation/LiberationMono-Regular.ttf",
            "/usr/share/fonts/truetype/noto/NotoSansMono-Regular.ttf",
        },
    };
}

pub fn symbol() []const []const u8 {
    return switch (builtin.target.os.tag) {
        .macos => &.{
            "/System/Library/Fonts/Apple Symbols.ttf",
            "/System/Library/Fonts/Symbol.ttf",
        },
        .windows => &.{
            "C:\\Windows\\Fonts\\seguisym.ttf",
        },
        else => &.{
            "/usr/share/fonts/truetype/noto/NotoSansSymbols2-Regular.ttf",
            "/usr/share/fonts/truetype/noto/NotoSansSymbols-Regular.ttf",
        },
    };
}

pub fn cjk() []const []const u8 {
    return switch (builtin.target.os.tag) {
        .macos => &.{
            "/System/Library/Fonts/STHeiti Medium.ttc",
            "/System/Library/Fonts/Hiragino Sans GB.ttc",
            "/System/Library/Fonts/PingFang.ttc",
            "/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
            "/System/Library/Fonts/CJKSymbolsFallback.ttc",
        },
        .windows => &.{
            "C:\\Windows\\Fonts\\msyh.ttc",
            "C:\\Windows\\Fonts\\simsun.ttc",
            "C:\\Windows\\Fonts\\msgothic.ttc",
        },
        else => &.{
            "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
            "/usr/share/fonts/truetype/noto/NotoSansCJK-Regular.ttc",
            "/usr/share/fonts/truetype/arphic/uming.ttc",
        },
    };
}

pub fn emoji() []const []const u8 {
    return switch (builtin.target.os.tag) {
        .macos => &.{
            "/System/Library/Fonts/Apple Color Emoji.ttc",
        },
        .windows => &.{
            "C:\\Windows\\Fonts\\seguiemj.ttf",
        },
        else => &.{
            "/usr/share/fonts/truetype/noto/NotoColorEmoji.ttf",
            "/usr/share/fonts/google-noto-emoji/NotoColorEmoji.ttf",
        },
    };
}
