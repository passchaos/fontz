const builtin = @import("builtin");
const family_mod = @import("family.zig");
const types = @import("types.zig");

pub const Role = types.Role;

pub const CandidatePath = struct {
    path: []const u8,
    face_index: u32 = 0,
};

pub fn forRole(role: Role) []const []const u8 {
    return switch (role) {
        .ui => ui(),
        .monospace => monospace(),
        .cjk => cjk(),
        .emoji => emoji(),
        .symbol => symbol(),
    };
}

/// Deterministic fallback candidates for a semantic role. `language` selects
/// the CJK face (JP/KR/SC/TC/HK) and `weight`/`style` prefer bold/italic
/// variants when a platform ships them as separate files.
pub fn forRoleCandidates(
    role: Role,
    language: ?[]const u8,
    weight: u16,
    style: types.Style,
) []const CandidatePath {
    return switch (role) {
        .ui => selectStyled(&ui_regular, &ui_bold, &ui_italic, weight, style),
        .monospace => selectStyled(&mono_regular, &mono_bold, &mono_italic, weight, style),
        .cjk => cjkCandidates(language, weight, style),
        .emoji => &emoji_candidates,
        .symbol => &symbol_candidates,
    };
}

/// Fallback candidates for a query. Only generic families, recognized role
/// names and codepoint-derived scripts are eligible; an unknown concrete
/// family returns an empty list so a missing authored font is not silently
/// replaced by a UI font.
pub fn forQuery(query: types.Query) []const CandidatePath {
    if (query.postscript_name != null) return &.{};
    var iterator = family_mod.FamilyIterator.init(query.family);
    var saw_concrete = false;
    while (iterator.next()) |raw_family| {
        const name = std.mem.trim(u8, raw_family, " \t\r\n");
        if (name.len == 0) continue;
        if (family_mod.genericFamily(name)) |generic| {
            return switch (generic) {
                .serif => serifCandidates(query.weight, query.style),
                .sans_serif, .system_ui, .rounded => if (query.required_codepoint) |codepoint| blk: {
                    if (roleForCodepoint(codepoint)) |role| {
                        break :blk forRoleCandidates(role, query.language, query.weight, query.style);
                    }
                    break :blk forRoleCandidates(.ui, query.language, query.weight, query.style);
                } else forRoleCandidates(
                    .ui,
                    query.language,
                    query.weight,
                    query.style,
                ),
                .monospace => forRoleCandidates(
                    .monospace,
                    query.language,
                    query.weight,
                    query.style,
                ),
                .cursive => &cursive_candidates,
                .fantasy => &fantasy_candidates,
                .emoji => forRoleCandidates(.emoji, query.language, query.weight, query.style),
                .math => &math_candidates,
            };
        }
        if (query.required_codepoint == null) {
            if (roleForFamilyName(name)) |role| {
                return forRoleCandidates(role, query.language, query.weight, query.style);
            }
        }
        saw_concrete = true;
    }
    if (query.required_codepoint) |codepoint| {
        if (roleForCodepoint(codepoint)) |role| {
            const language = query.language orelse
                if (role == .cjk) cjkLanguageForCodepoint(codepoint) else null;
            return forRoleCandidates(role, language, query.weight, query.style);
        }
        if (scriptForCodepoint(codepoint)) |script| return scriptCandidates(script);
        // Unknown/unassigned script: fall back to the platform's explicit
        // placeholder font instead of an unrelated UI font.
        return &last_resort_candidates;
    }
    if (query.family.len == 0 and !saw_concrete) {
        return forRoleCandidates(.ui, query.language, query.weight, query.style);
    }
    return &.{};
}

fn serifCandidates(weight: u16, style: types.Style) []const CandidatePath {
    if (style != .normal) return &serif_italic;
    if (weight >= 600) return &serif_bold;
    return &serif_regular;
}

fn roleForFamilyName(name: []const u8) ?Role {
    if (containsIgnoreCase(name, "emoji")) return .emoji;
    if (containsIgnoreCase(name, "symbol")) return .symbol;
    if (containsIgnoreCase(name, "mono")) return .monospace;
    if (containsIgnoreCase(name, "cjk") or containsIgnoreCase(name, "mincho") or
        containsIgnoreCase(name, "gothic") or containsIgnoreCase(name, "song") or
        containsIgnoreCase(name, "hei") or containsIgnoreCase(name, "ming"))
    {
        return .cjk;
    }
    if (containsIgnoreCase(name, "sans") or containsIgnoreCase(name, "arial") or
        containsIgnoreCase(name, "helvetica") or containsIgnoreCase(name, "segoe"))
    {
        return .ui;
    }
    return null;
}

pub fn roleForCodepoint(codepoint: u21) ?Role {
    if (isEmojiCodepoint(codepoint)) return .emoji;
    if (isCjkCodepoint(codepoint)) return .cjk;
    if (isMathCodepoint(codepoint)) return .symbol;
    if (isSymbolCodepoint(codepoint)) return .symbol;
    return null;
}

const Script = enum {
    arabic,
    hebrew,
    thai,
    devanagari,
    bengali,
    tamil,
    telugu,
    kannada,
    malayalam,
    gujarati,
    gurmukhi,
    sinhala,
    khmer,
    lao,
    myanmar,
    georgian,
    armenian,
    ethiopic,
    syriac,
    thaana,
    oriya,
    tibetan,
    mongolian,
    cherokee,
    canadian_aboriginal,
    tifinagh,
    ol_chiki,
    javanese,
    sundanese,
    balinese,
    batak,
    lepcha,
    vai,
    bamum,
    adlam,
    meetei_mayek,
    yi,
};

fn scriptForCodepoint(codepoint: u21) ?Script {
    return switch (codepoint) {
        0x0590...0x05ff => .hebrew,
        0x0600...0x06ff, 0x0750...0x077f, 0x08a0...0x08ff, 0xfb50...0xfdff, 0xfe70...0xfeff => .arabic,
        0x0900...0x097f => .devanagari,
        0x0980...0x09ff => .bengali,
        0x0a00...0x0a7f => .gurmukhi,
        0x0a80...0x0aff => .gujarati,
        0x0b80...0x0bff => .tamil,
        0x0c00...0x0c7f => .telugu,
        0x0c80...0x0cff => .kannada,
        0x0d00...0x0d7f => .malayalam,
        0x0d80...0x0dff => .sinhala,
        0x0e00...0x0e7f => .thai,
        0x0e80...0x0eff => .lao,
        0x1000...0x109f => .myanmar,
        0x10a0...0x10ff => .georgian,
        0x1200...0x137f => .ethiopic,
        0x1780...0x17ff => .khmer,
        0x0530...0x058f => .armenian,
        0x0700...0x074f => .syriac,
        0x0780...0x07bf => .thaana,
        0x0b00...0x0b7f => .oriya,
        0x0f00...0x0fff => .tibetan,
        0x1800...0x18af => .mongolian,
        0x13a0...0x13ff, 0xab70...0xabbf => .cherokee,
        0x1400...0x167f, 0x18b0...0x18ff => .canadian_aboriginal,
        0x2d30...0x2d7f => .tifinagh,
        0x1c50...0x1c7f => .ol_chiki,
        0xa980...0xa9df => .javanese,
        0x1b80...0x1bbf => .sundanese,
        0x1b00...0x1b7f => .balinese,
        0x1bc0...0x1bff => .batak,
        0x1c00...0x1c4f => .lepcha,
        0xa500...0xa63f => .vai,
        0xa6a0...0xa6ff, 0x16800...0x16a3f => .bamum,
        0x1e900...0x1e95f => .adlam,
        0xabc0...0xabff, 0xaae0...0xaaff => .meetei_mayek,
        0xa000...0xa48f => .yi,
        else => null,
    };
}

fn scriptCandidates(script: Script) []const CandidatePath {
    return switch (script) {
        .arabic => &arabic_candidates,
        .hebrew => &hebrew_candidates,
        .thai => &thai_candidates,
        .devanagari => &devanagari_candidates,
        .bengali => &bengali_candidates,
        .tamil => &tamil_candidates,
        .telugu => &telugu_candidates,
        .kannada => &kannada_candidates,
        .malayalam => &malayalam_candidates,
        .gujarati => &gujarati_candidates,
        .gurmukhi => &gurmukhi_candidates,
        .sinhala => &sinhala_candidates,
        .khmer => &khmer_candidates,
        .lao => &lao_candidates,
        .myanmar => &myanmar_candidates,
        .georgian => &georgian_candidates,
        .armenian => &armenian_candidates,
        .ethiopic => &ethiopic_candidates,
        .syriac => &syriac_candidates,
        .thaana => &thaana_candidates,
        .oriya => &oriya_candidates,
        .tibetan => &tibetan_candidates,
        .mongolian => &mongolian_candidates,
        .cherokee => &cherokee_candidates,
        .canadian_aboriginal => &canadian_aboriginal_candidates,
        .tifinagh => &tifinagh_candidates,
        .ol_chiki => &ol_chiki_candidates,
        .javanese => &javanese_candidates,
        .sundanese => &sundanese_candidates,
        .balinese => &balinese_candidates,
        .batak => &batak_candidates,
        .lepcha => &lepcha_candidates,
        .vai => &vai_candidates,
        .bamum => &bamum_candidates,
        .adlam => &adlam_candidates,
        .meetei_mayek => &meetei_mayek_candidates,
        .yi => &yi_candidates,
    };
}

const CjkLanguage = enum { ja, ko, sc, tc, hk };

fn cjkLanguage(language: ?[]const u8, families: []const u8) CjkLanguage {
    if (language) |value| {
        if (startsWithLanguage(value, "ja")) return .ja;
        if (startsWithLanguage(value, "ko")) return .ko;
        if (startsWithLanguage(value, "zh-hk") or startsWithLanguage(value, "zh-hant-hk")) return .hk;
        if (startsWithLanguage(value, "zh-tw") or startsWithLanguage(value, "zh-hant")) return .tc;
        if (startsWithLanguage(value, "zh")) return .sc;
    }
    if (containsIgnoreCase(families, "cjk jp") or containsIgnoreCase(families, "mincho")) return .ja;
    if (containsIgnoreCase(families, "cjk kr")) return .ko;
    if (containsIgnoreCase(families, "cjk tc") or containsIgnoreCase(families, "ming")) return .tc;
    if (containsIgnoreCase(families, "cjk hk")) return .hk;
    return .sc;
}

fn cjkCandidates(language: ?[]const u8, weight: u16, style: types.Style) []const CandidatePath {
    _ = style;
    const bold = weight >= 600;
    const lang = cjkLanguage(language, "");
    return switch (lang) {
        .ja => if (bold) &cjk_ja_bold else &cjk_ja_regular,
        .ko => if (bold) &cjk_ko_bold else &cjk_ko_regular,
        .sc => if (bold) &cjk_sc_bold else &cjk_sc_regular,
        .tc => if (bold) &cjk_tc_bold else &cjk_tc_regular,
        .hk => if (bold) &cjk_hk_bold else &cjk_hk_regular,
    };
}

fn selectStyled(
    regular: []const CandidatePath,
    bold: []const CandidatePath,
    italic: []const CandidatePath,
    weight: u16,
    style: types.Style,
) []const CandidatePath {
    if (style != .normal) return italic;
    if (weight >= 600) return bold;
    return regular;
}

fn cjkLanguageForCodepoint(codepoint: u21) ?[]const u8 {
    return switch (codepoint) {
        0x3040...0x30ff, 0x31f0...0x31ff => "ja",
        0x1100...0x11ff, 0x3130...0x318f, 0xac00...0xd7af => "ko",
        else => null,
    };
}

fn startsWithLanguage(language: []const u8, prefix: []const u8) bool {
    if (language.len < prefix.len) return false;
    for (language[0..prefix.len], prefix) |actual, expected| {
        const normalized = if (actual == '_') '-' else std.ascii.toLower(actual);
        if (normalized != std.ascii.toLower(expected)) return false;
    }
    return language.len == prefix.len or language[prefix.len] == '-' or
        language[prefix.len] == '_';
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[index..][0..needle.len], needle)) return true;
    }
    return false;
}

fn isEmojiCodepoint(codepoint: u21) bool {
    return (codepoint >= 0x1f000 and codepoint <= 0x1faff) or
        (codepoint >= 0x2600 and codepoint <= 0x27bf) or
        (codepoint >= 0x1f1e6 and codepoint <= 0x1f1ff) or
        codepoint == 0xfe0f or codepoint == 0x20e3;
}

fn isCjkCodepoint(codepoint: u21) bool {
    return (codepoint >= 0x2e80 and codepoint <= 0x9fff) or
        (codepoint >= 0xac00 and codepoint <= 0xd7ff) or
        (codepoint >= 0xf900 and codepoint <= 0xfaff) or
        (codepoint >= 0xfe30 and codepoint <= 0xfe4f) or
        (codepoint >= 0xff00 and codepoint <= 0xffef) or
        (codepoint >= 0x20000 and codepoint <= 0x2fa1f) or
        (codepoint >= 0x30000 and codepoint <= 0x3134f);
}

fn isMathCodepoint(codepoint: u21) bool {
    return (codepoint >= 0x2200 and codepoint <= 0x22ff) or
        (codepoint >= 0x27c0 and codepoint <= 0x27ef) or
        (codepoint >= 0x2980 and codepoint <= 0x2aff) or
        (codepoint >= 0x1d400 and codepoint <= 0x1d7ff);
}

fn isSymbolCodepoint(codepoint: u21) bool {
    return (codepoint >= 0x2190 and codepoint <= 0x21ff) or
        (codepoint >= 0x2300 and codepoint <= 0x23ff) or
        (codepoint >= 0x25a0 and codepoint <= 0x25ff) or
        (codepoint >= 0x2b00 and codepoint <= 0x2bff);
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
            "/usr/share/fonts/truetype/liberation2/LiberationSans-Regular.ttf",
            "/usr/share/fonts/noto/NotoSans-Regular.ttf",
            "/usr/share/fonts/truetype/noto/NotoSans-Regular.ttf",
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
            "/usr/share/fonts/truetype/liberation2/LiberationMono-Regular.ttf",
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
            "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
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

const ui_regular = [_]CandidatePath{
    .{ .path = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf" },
    .{ .path = "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf" },
    .{ .path = "/usr/share/fonts/truetype/liberation2/LiberationSans-Regular.ttf" },
    .{ .path = "/usr/share/fonts/truetype/noto/NotoSans-Regular.ttf" },
    .{ .path = "/usr/share/fonts/noto/NotoSans-Regular.ttf" },
    .{ .path = "/System/Library/Fonts/SFNS.ttf" },
    .{ .path = "/System/Library/Fonts/HelveticaNeue.ttc" },
    .{ .path = "C:\\Windows\\Fonts\\segoeui.ttf" },
    .{ .path = "C:\\Windows\\Fonts\\arial.ttf" },
};

const ui_bold = [_]CandidatePath{
    .{ .path = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf" },
    .{ .path = "/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf" },
    .{ .path = "/usr/share/fonts/truetype/liberation2/LiberationSans-Bold.ttf" },
    .{ .path = "/usr/share/fonts/truetype/noto/NotoSans-Bold.ttf" },
    .{ .path = "/System/Library/Fonts/Supplemental/Arial Bold.ttf" },
    .{ .path = "C:\\Windows\\Fonts\\segoeuib.ttf" },
    .{ .path = "C:\\Windows\\Fonts\\arialbd.ttf" },
};

const ui_italic = [_]CandidatePath{
    .{ .path = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Oblique.ttf" },
    .{ .path = "/usr/share/fonts/truetype/liberation/LiberationSans-Italic.ttf" },
    .{ .path = "/usr/share/fonts/truetype/liberation2/LiberationSans-Italic.ttf" },
    .{ .path = "/usr/share/fonts/truetype/noto/NotoSans-Italic.ttf" },
    .{ .path = "/System/Library/Fonts/Supplemental/Arial Italic.ttf" },
    .{ .path = "C:\\Windows\\Fonts\\segoeuii.ttf" },
    .{ .path = "C:\\Windows\\Fonts\\ariali.ttf" },
};

const mono_regular = [_]CandidatePath{
    .{ .path = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf" },
    .{ .path = "/usr/share/fonts/truetype/liberation/LiberationMono-Regular.ttf" },
    .{ .path = "/usr/share/fonts/truetype/liberation2/LiberationMono-Regular.ttf" },
    .{ .path = "/usr/share/fonts/truetype/noto/NotoSansMono-Regular.ttf" },
    .{ .path = "/System/Library/Fonts/SFNSMono.ttf" },
    .{ .path = "/System/Library/Fonts/Menlo.ttc" },
    .{ .path = "C:\\Windows\\Fonts\\CascadiaMono.ttf" },
    .{ .path = "C:\\Windows\\Fonts\\consola.ttf" },
};

const mono_bold = [_]CandidatePath{
    .{ .path = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf" },
    .{ .path = "/usr/share/fonts/truetype/liberation/LiberationMono-Bold.ttf" },
    .{ .path = "/usr/share/fonts/truetype/liberation2/LiberationMono-Bold.ttf" },
    .{ .path = "/usr/share/fonts/truetype/noto/NotoSansMono-Bold.ttf" },
    .{ .path = "C:\\Windows\\Fonts\\consolab.ttf" },
};

const mono_italic = [_]CandidatePath{
    .{ .path = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Oblique.ttf" },
    .{ .path = "/usr/share/fonts/truetype/liberation/LiberationMono-Italic.ttf" },
    .{ .path = "/usr/share/fonts/truetype/liberation2/LiberationMono-Italic.ttf" },
    .{ .path = "C:\\Windows\\Fonts\\consolai.ttf" },
};

const emoji_candidates = [_]CandidatePath{
    .{ .path = "/usr/share/fonts/truetype/noto/NotoColorEmoji.ttf" },
    .{ .path = "/usr/share/fonts/google-noto-emoji/NotoColorEmoji.ttf" },
    .{ .path = "/System/Library/Fonts/Apple Color Emoji.ttc" },
    .{ .path = "C:\\Windows\\Fonts\\seguiemj.ttf" },
};

const symbol_candidates = [_]CandidatePath{
    .{ .path = "/usr/share/fonts/truetype/noto/NotoSansSymbols2-Regular.ttf" },
    .{ .path = "/usr/share/fonts/truetype/noto/NotoSansSymbols-Regular.ttf" },
    .{ .path = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf" },
    .{ .path = "/System/Library/Fonts/Apple Symbols.ttf" },
    .{ .path = "C:\\Windows\\Fonts\\seguisym.ttf" },
};

const serif_regular = [_]CandidatePath{
    .{ .path = "/usr/share/fonts/truetype/dejavu/DejaVuSerif.ttf" },
    .{ .path = "/usr/share/fonts/truetype/liberation/LiberationSerif-Regular.ttf" },
    .{ .path = "/usr/share/fonts/truetype/liberation2/LiberationSerif-Regular.ttf" },
    .{ .path = "/usr/share/fonts/truetype/noto/NotoSerif-Regular.ttf" },
    .{ .path = "/System/Library/Fonts/NewYork.ttf" },
    .{ .path = "/System/Library/Fonts/Times.ttc" },
    .{ .path = "/System/Library/Fonts/Supplemental/Times New Roman.ttf" },
    .{ .path = "C:\\Windows\\Fonts\\times.ttf" },
    .{ .path = "C:\\Windows\\Fonts\\georgia.ttf" },
};

const serif_bold = [_]CandidatePath{
    .{ .path = "/usr/share/fonts/truetype/dejavu/DejaVuSerif-Bold.ttf" },
    .{ .path = "/usr/share/fonts/truetype/liberation/LiberationSerif-Bold.ttf" },
    .{ .path = "/usr/share/fonts/truetype/liberation2/LiberationSerif-Bold.ttf" },
    .{ .path = "/usr/share/fonts/truetype/noto/NotoSerif-Bold.ttf" },
    .{ .path = "/System/Library/Fonts/Supplemental/Times New Roman Bold.ttf" },
    .{ .path = "C:\\Windows\\Fonts\\timesbd.ttf" },
    .{ .path = "C:\\Windows\\Fonts\\georgiab.ttf" },
};

const serif_italic = [_]CandidatePath{
    .{ .path = "/usr/share/fonts/truetype/dejavu/DejaVuSerif-Italic.ttf" },
    .{ .path = "/usr/share/fonts/truetype/liberation/LiberationSerif-Italic.ttf" },
    .{ .path = "/usr/share/fonts/truetype/liberation2/LiberationSerif-Italic.ttf" },
    .{ .path = "/usr/share/fonts/truetype/noto/NotoSerif-Italic.ttf" },
    .{ .path = "/System/Library/Fonts/Supplemental/Times New Roman Italic.ttf" },
    .{ .path = "C:\\Windows\\Fonts\\timesi.ttf" },
    .{ .path = "C:\\Windows\\Fonts\\georgiai.ttf" },
};

const math_candidates = [_]CandidatePath{
    .{ .path = "/usr/share/texmf/fonts/opentype/public/lm-math/latinmodern-math.otf" },
    .{ .path = "/usr/share/fonts/truetype/noto/NotoSansMath-Regular.ttf" },
    .{ .path = "/usr/share/fonts/truetype/dejavu/DejaVuMathTeXGyre.ttf" },
    .{ .path = "/System/Library/Fonts/Supplemental/STIXTwoMath.otf" },
    .{ .path = "/System/Library/Fonts/Supplemental/STIXGeneral.otf" },
    .{ .path = "/System/Library/Fonts/Apple Symbols.ttf" },
    .{ .path = "C:\\Windows\\Fonts\\cambria.ttc" },
    .{ .path = "C:\\Windows\\Fonts\\seguisym.ttf" },
};

const cursive_candidates = [_]CandidatePath{
    .{ .path = "/usr/share/fonts/opentype/urw-base35/Z003-MediumItalic.otf" },
    .{ .path = "/System/Library/Fonts/Apple Chancery.ttf" },
    .{ .path = "C:\\Windows\\Fonts\\segoesc.ttf" },
    .{ .path = "C:\\Windows\\Fonts\\comic.ttf" },
};

const fantasy_candidates = [_]CandidatePath{
    .{ .path = "/usr/share/fonts/opentype/urw-base35/Z003-MediumItalic.otf" },
    .{ .path = "/System/Library/Fonts/Papyrus.ttc" },
    .{ .path = "/System/Library/Fonts/Supplemental/Chalkboard.ttc" },
    .{ .path = "C:\\Windows\\Fonts\\impact.ttf" },
    .{ .path = "C:\\Windows\\Fonts\\segoepr.ttf" },
};

const cjk_ja_regular = [_]CandidatePath{
    .{ .path = "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc", .face_index = 0 },
    .{ .path = "/usr/share/fonts/opentype/noto/NotoSansCJKjp-Regular.otf" },
    .{ .path = "/usr/share/fonts/truetype/noto/NotoSansCJK-Regular.ttc", .face_index = 0 },
    .{ .path = "/System/Library/Fonts/Hiragino Sans GB.ttc" },
    .{ .path = "/System/Library/Fonts/Supplemental/Arial Unicode.ttf" },
    .{ .path = "C:\\Windows\\Fonts\\msgothic.ttc" },
};

const cjk_ja_bold = [_]CandidatePath{
    .{ .path = "/usr/share/fonts/opentype/noto/NotoSansCJK-Bold.ttc", .face_index = 0 },
    .{ .path = "/usr/share/fonts/opentype/noto/NotoSansCJKjp-Bold.otf" },
    .{ .path = "/usr/share/fonts/truetype/noto/NotoSansCJK-Bold.ttc", .face_index = 0 },
    .{ .path = "C:\\Windows\\Fonts\\msgothic.ttc" },
};

const cjk_ko_regular = [_]CandidatePath{
    .{ .path = "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc", .face_index = 1 },
    .{ .path = "/usr/share/fonts/opentype/noto/NotoSansCJKkr-Regular.otf" },
    .{ .path = "/usr/share/fonts/truetype/noto/NotoSansCJK-Regular.ttc", .face_index = 1 },
    .{ .path = "/System/Library/Fonts/AppleSDGothicNeo.ttc" },
    .{ .path = "/System/Library/Fonts/Supplemental/Arial Unicode.ttf" },
    .{ .path = "C:\\Windows\\Fonts\\malgun.ttf" },
};

const cjk_ko_bold = [_]CandidatePath{
    .{ .path = "/usr/share/fonts/opentype/noto/NotoSansCJK-Bold.ttc", .face_index = 1 },
    .{ .path = "/usr/share/fonts/opentype/noto/NotoSansCJKkr-Bold.otf" },
    .{ .path = "/usr/share/fonts/truetype/noto/NotoSansCJK-Bold.ttc", .face_index = 1 },
    .{ .path = "C:\\Windows\\Fonts\\malgunbd.ttf" },
};

const cjk_sc_regular = [_]CandidatePath{
    .{ .path = "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc", .face_index = 2 },
    .{ .path = "/usr/share/fonts/opentype/noto/NotoSansCJKsc-Regular.otf" },
    .{ .path = "/usr/share/fonts/truetype/noto/NotoSansCJK-Regular.ttc", .face_index = 2 },
    .{ .path = "/System/Library/PrivateFrameworks/FontServices.framework/Versions/Current/Resources/Reserved/PingFangUI.ttc", .face_index = 20 },
    .{ .path = "/System/Library/Fonts/Hiragino Sans GB.ttc" },
    .{ .path = "/System/Library/Fonts/Supplemental/Arial Unicode.ttf" },
    .{ .path = "C:\\Windows\\Fonts\\msyh.ttc" },
};

const cjk_sc_bold = [_]CandidatePath{
    .{ .path = "/usr/share/fonts/opentype/noto/NotoSansCJK-Bold.ttc", .face_index = 2 },
    .{ .path = "/usr/share/fonts/opentype/noto/NotoSansCJKsc-Bold.otf" },
    .{ .path = "/usr/share/fonts/truetype/noto/NotoSansCJK-Bold.ttc", .face_index = 2 },
    .{ .path = "C:\\Windows\\Fonts\\msyhbd.ttc" },
};

const cjk_tc_regular = [_]CandidatePath{
    .{ .path = "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc", .face_index = 3 },
    .{ .path = "/usr/share/fonts/opentype/noto/NotoSansCJKtc-Regular.otf" },
    .{ .path = "/usr/share/fonts/truetype/noto/NotoSansCJK-Regular.ttc", .face_index = 3 },
    .{ .path = "/System/Library/PrivateFrameworks/FontServices.framework/Versions/Current/Resources/Reserved/PingFangUI.ttc", .face_index = 21 },
    .{ .path = "/System/Library/Fonts/Hiragino Sans GB.ttc" },
    .{ .path = "/System/Library/Fonts/Supplemental/Arial Unicode.ttf" },
    .{ .path = "/usr/share/fonts/truetype/arphic/uming.ttc" },
    .{ .path = "C:\\Windows\\Fonts\\msjh.ttc" },
};

const cjk_tc_bold = [_]CandidatePath{
    .{ .path = "/usr/share/fonts/opentype/noto/NotoSansCJK-Bold.ttc", .face_index = 3 },
    .{ .path = "/usr/share/fonts/opentype/noto/NotoSansCJKtc-Bold.otf" },
    .{ .path = "/usr/share/fonts/truetype/noto/NotoSansCJK-Bold.ttc", .face_index = 3 },
    .{ .path = "C:\\Windows\\Fonts\\msjhbd.ttc" },
};

const cjk_hk_regular = [_]CandidatePath{
    .{ .path = "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc", .face_index = 4 },
    .{ .path = "/usr/share/fonts/opentype/noto/NotoSansCJKhk-Regular.otf" },
    .{ .path = "/usr/share/fonts/truetype/noto/NotoSansCJK-Regular.ttc", .face_index = 4 },
    .{ .path = "C:\\Windows\\Fonts\\msjh.ttc" },
};

const cjk_hk_bold = [_]CandidatePath{
    .{ .path = "/usr/share/fonts/opentype/noto/NotoSansCJK-Bold.ttc", .face_index = 4 },
    .{ .path = "/usr/share/fonts/opentype/noto/NotoSansCJKhk-Bold.otf" },
    .{ .path = "/usr/share/fonts/truetype/noto/NotoSansCJK-Bold.ttc", .face_index = 4 },
    .{ .path = "C:\\Windows\\Fonts\\msjhbd.ttc" },
};

const arabic_candidates = [_]CandidatePath{
    .{ .path = "/System/Library/Fonts/SFArabic.ttf" },
    .{ .path = "/System/Library/Fonts/GeezaPro.ttc" },
    .{ .path = "/usr/share/fonts/truetype/noto/NotoSansArabic-Regular.ttf" },
    .{ .path = "/usr/share/fonts/truetype/noto/NotoSansArabicUI-Regular.ttf" },
    .{ .path = "C:\\Windows\\Fonts\\segoeui.ttf" },
    .{ .path = "/System/Library/Fonts/Supplemental/Arial Unicode.ttf" },
    .{ .path = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf" },
};

const hebrew_candidates = [_]CandidatePath{
    .{ .path = "/System/Library/Fonts/LucidaGrande.ttc" },
    .{ .path = "/usr/share/fonts/truetype/noto/NotoSansHebrew-Regular.ttf" },
    .{ .path = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf" },
    .{ .path = "/System/Library/Fonts/Supplemental/Arial Unicode.ttf" },
};

const thai_candidates = [_]CandidatePath{
    .{ .path = "/System/Library/Fonts/ThonburiUI.ttc" },
    .{ .path = "/System/Library/Fonts/Supplemental/Thonburi.ttc" },
    .{ .path = "/usr/share/fonts/truetype/noto/NotoSansThai-Regular.ttf" },
    .{ .path = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf" },
    .{ .path = "C:\\Windows\\Fonts\\LeelawadeeUI.ttf" },
    .{ .path = "/System/Library/Fonts/Supplemental/Arial Unicode.ttf" },
};

const devanagari_candidates = [_]CandidatePath{
    .{ .path = "/System/Library/Fonts/Kohinoor.ttc" },
    .{ .path = "/usr/share/fonts/truetype/noto/NotoSansDevanagari-Regular.ttf" },
    .{ .path = "C:\\Windows\\Fonts\\Nirmala.ttf" },
    .{ .path = "/System/Library/Fonts/Supplemental/Arial Unicode.ttf" },
};

const bengali_candidates = [_]CandidatePath{
    .{ .path = "/System/Library/Fonts/KohinoorBangla.ttc" },
    .{ .path = "/usr/share/fonts/truetype/noto/NotoSansBengali-Regular.ttf" },
    .{ .path = "C:\\Windows\\Fonts\\Nirmala.ttf" },
    .{ .path = "/System/Library/Fonts/Supplemental/Arial Unicode.ttf" },
};

const tamil_candidates = [_]CandidatePath{
    .{ .path = "/usr/share/fonts/truetype/noto/NotoSansTamil-Regular.ttf" },
    .{ .path = "C:\\Windows\\Fonts\\Nirmala.ttf" },
    .{ .path = "/System/Library/Fonts/Supplemental/Arial Unicode.ttf" },
};

const telugu_candidates = [_]CandidatePath{
    .{ .path = "/System/Library/Fonts/KohinoorTelugu.ttc" },
    .{ .path = "/usr/share/fonts/truetype/noto/NotoSansTelugu-Regular.ttf" },
    .{ .path = "C:\\Windows\\Fonts\\Nirmala.ttf" },
    .{ .path = "/System/Library/Fonts/Supplemental/Arial Unicode.ttf" },
};

const kannada_candidates = [_]CandidatePath{
    .{ .path = "/usr/share/fonts/truetype/noto/NotoSansKannada-Regular.ttf" },
    .{ .path = "C:\\Windows\\Fonts\\Nirmala.ttf" },
    .{ .path = "/System/Library/Fonts/Supplemental/Arial Unicode.ttf" },
};

const malayalam_candidates = [_]CandidatePath{
    .{ .path = "/usr/share/fonts/truetype/noto/NotoSansMalayalam-Regular.ttf" },
    .{ .path = "C:\\Windows\\Fonts\\Nirmala.ttf" },
    .{ .path = "/System/Library/Fonts/Supplemental/Arial Unicode.ttf" },
};

const gujarati_candidates = [_]CandidatePath{
    .{ .path = "/System/Library/Fonts/KohinoorGujarati.ttc" },
    .{ .path = "/usr/share/fonts/truetype/noto/NotoSansGujarati-Regular.ttf" },
    .{ .path = "C:\\Windows\\Fonts\\Nirmala.ttf" },
    .{ .path = "/System/Library/Fonts/Supplemental/Arial Unicode.ttf" },
};

const gurmukhi_candidates = [_]CandidatePath{
    .{ .path = "/usr/share/fonts/truetype/noto/NotoSansGurmukhi-Regular.ttf" },
    .{ .path = "C:\\Windows\\Fonts\\Nirmala.ttf" },
    .{ .path = "/System/Library/Fonts/Supplemental/Arial Unicode.ttf" },
};

const sinhala_candidates = [_]CandidatePath{
    .{ .path = "/usr/share/fonts/truetype/noto/NotoSansSinhala-Regular.ttf" },
    .{ .path = "C:\\Windows\\Fonts\\Nirmala.ttf" },
    .{ .path = "/System/Library/Fonts/Supplemental/Arial Unicode.ttf" },
};

const khmer_candidates = [_]CandidatePath{
    .{ .path = "/usr/share/fonts/truetype/noto/NotoSansKhmer-Regular.ttf" },
    .{ .path = "C:\\Windows\\Fonts\\LeelawadeeUI.ttf" },
    .{ .path = "/System/Library/Fonts/Supplemental/Arial Unicode.ttf" },
};

const lao_candidates = [_]CandidatePath{
    .{ .path = "/usr/share/fonts/truetype/noto/NotoSansLao-Regular.ttf" },
    .{ .path = "C:\\Windows\\Fonts\\LeelawadeeUI.ttf" },
    .{ .path = "/System/Library/Fonts/Supplemental/Arial Unicode.ttf" },
};

const myanmar_candidates = [_]CandidatePath{
    .{ .path = "/usr/share/fonts/truetype/noto/NotoSansMyanmar-Regular.ttf" },
    .{ .path = "C:\\Windows\\Fonts\\MyanmarText.ttf" },
    .{ .path = "/System/Library/Fonts/Supplemental/Arial Unicode.ttf" },
};

const georgian_candidates = [_]CandidatePath{
    .{ .path = "/usr/share/fonts/truetype/noto/NotoSansGeorgian-Regular.ttf" },
    .{ .path = "/System/Library/Fonts/Supplemental/Arial Unicode.ttf" },
};

const armenian_candidates = [_]CandidatePath{
    .{ .path = "/System/Library/Fonts/NotoSansArmenian.ttc" },
    .{ .path = "/System/Library/Fonts/SFArmenian.ttf" },
    .{ .path = "/usr/share/fonts/truetype/noto/NotoSansArmenian-Regular.ttf" },
    .{ .path = "/System/Library/Fonts/Supplemental/Arial Unicode.ttf" },
};

const ethiopic_candidates = [_]CandidatePath{
    .{ .path = "/usr/share/fonts/truetype/noto/NotoSansEthiopic-Regular.ttf" },
    .{ .path = "C:\\Windows\\Fonts\\Ebrima.ttf" },
    .{ .path = "/System/Library/Fonts/Supplemental/Arial Unicode.ttf" },
};

const syriac_candidates = [_]CandidatePath{
    .{ .path = "/System/Library/Fonts/Supplemental/NotoSansSyriac-Regular.ttf" },
    .{ .path = "/usr/share/fonts/truetype/noto/NotoSansSyriac-Regular.ttf" },
    .{ .path = "C:\\Windows\\Fonts\\Estrangelo Edessa.ttf" },
    .{ .path = "/System/Library/Fonts/Supplemental/Arial Unicode.ttf" },
};

const thaana_candidates = [_]CandidatePath{
    .{ .path = "/System/Library/Fonts/Supplemental/NotoSansThaana-Regular.ttf" },
    .{ .path = "/usr/share/fonts/truetype/noto/NotoSansThaana-Regular.ttf" },
    .{ .path = "C:\\Windows\\Fonts\\mvboli.ttf" },
    .{ .path = "/System/Library/Fonts/Supplemental/Arial Unicode.ttf" },
};

const oriya_candidates = [_]CandidatePath{
    .{ .path = "/System/Library/Fonts/NotoSansOriya.ttc" },
    .{ .path = "/usr/share/fonts/truetype/noto/NotoSansOriya-Regular.ttf" },
    .{ .path = "C:\\Windows\\Fonts\\Nirmala.ttf" },
    .{ .path = "/System/Library/Fonts/Supplemental/Arial Unicode.ttf" },
};

const tibetan_candidates = [_]CandidatePath{
    .{ .path = "/System/Library/Fonts/Kailasa.ttc" },
    .{ .path = "/System/Library/Fonts/Supplemental/Kokonor.ttf" },
    .{ .path = "/usr/share/fonts/truetype/noto/NotoSerifTibetan-Regular.ttf" },
    .{ .path = "C:\\Windows\\Fonts\\Microsoft Himalaya.ttf" },
    .{ .path = "/System/Library/Fonts/Supplemental/Arial Unicode.ttf" },
};

const mongolian_candidates = [_]CandidatePath{
    .{ .path = "/System/Library/Fonts/Supplemental/NotoSansMongolian-Regular.ttf" },
    .{ .path = "/usr/share/fonts/truetype/noto/NotoSansMongolian-Regular.ttf" },
    .{ .path = "C:\\Windows\\Fonts\\Mongolian Baiti.ttf" },
};

const cherokee_candidates = [_]CandidatePath{
    .{ .path = "/System/Library/Fonts/Supplemental/PlantagenetCherokee.ttf" },
    .{ .path = "/usr/share/fonts/truetype/noto/NotoSansCherokee-Regular.ttf" },
    .{ .path = "C:\\Windows\\Fonts\\Gadugi.ttf" },
};

const canadian_aboriginal_candidates = [_]CandidatePath{
    .{ .path = "/System/Library/Fonts/Supplemental/EuphemiaCAS.ttc" },
    .{ .path = "/System/Library/Fonts/Supplemental/NotoSansCanadianAboriginal-Regular.otf" },
    .{ .path = "/usr/share/fonts/truetype/noto/NotoSansCanadianAboriginal-Regular.ttf" },
    .{ .path = "C:\\Windows\\Fonts\\Gadugi.ttf" },
};

const tifinagh_candidates = [_]CandidatePath{
    .{ .path = "/System/Library/Fonts/Supplemental/NotoSansTifinagh-Regular.otf" },
    .{ .path = "/usr/share/fonts/truetype/noto/NotoSansTifinagh-Regular.ttf" },
    .{ .path = "C:\\Windows\\Fonts\\Ebrima.ttf" },
};

const ol_chiki_candidates = [_]CandidatePath{
    .{ .path = "/System/Library/Fonts/Supplemental/NotoSansOlChiki-Regular.ttf" },
    .{ .path = "/usr/share/fonts/truetype/noto/NotoSansOlChiki-Regular.ttf" },
    .{ .path = "/System/Library/Fonts/Supplemental/Arial Unicode.ttf" },
};

const javanese_candidates = [_]CandidatePath{
    .{ .path = "/System/Library/Fonts/Supplemental/NotoSansJavanese-Regular.otf" },
    .{ .path = "/usr/share/fonts/truetype/noto/NotoSansJavanese-Regular.ttf" },
    .{ .path = "C:\\Windows\\Fonts\\Javanese Text.ttf" },
};

const sundanese_candidates = [_]CandidatePath{
    .{ .path = "/System/Library/Fonts/Supplemental/NotoSansSundanese-Regular.ttf" },
    .{ .path = "/usr/share/fonts/truetype/noto/NotoSansSundanese-Regular.ttf" },
    .{ .path = "C:\\Windows\\Fonts\\Sundanese Text.ttf" },
};

const balinese_candidates = [_]CandidatePath{
    .{ .path = "/System/Library/Fonts/Supplemental/NotoSerifBalinese-Regular.ttf" },
    .{ .path = "/usr/share/fonts/truetype/noto/NotoSansBalinese-Regular.ttf" },
};

const batak_candidates = [_]CandidatePath{
    .{ .path = "/System/Library/Fonts/Supplemental/NotoSansBatak-Regular.ttf" },
    .{ .path = "/usr/share/fonts/truetype/noto/NotoSansBatak-Regular.ttf" },
};

const lepcha_candidates = [_]CandidatePath{
    .{ .path = "/System/Library/Fonts/Supplemental/NotoSansLepcha-Regular.ttf" },
    .{ .path = "/usr/share/fonts/truetype/noto/NotoSansLepcha-Regular.ttf" },
};

const vai_candidates = [_]CandidatePath{
    .{ .path = "/System/Library/Fonts/Supplemental/NotoSansVai-Regular.ttf" },
    .{ .path = "/usr/share/fonts/truetype/noto/NotoSansVai-Regular.ttf" },
    .{ .path = "C:\\Windows\\Fonts\\Ebrima.ttf" },
};

const bamum_candidates = [_]CandidatePath{
    .{ .path = "/System/Library/Fonts/Supplemental/NotoSansBamum-Regular.ttf" },
    .{ .path = "/usr/share/fonts/truetype/noto/NotoSansBamum-Regular.ttf" },
    .{ .path = "C:\\Windows\\Fonts\\Ebrima.ttf" },
};

const adlam_candidates = [_]CandidatePath{
    .{ .path = "/System/Library/Fonts/Supplemental/NotoSansAdlam-Regular.ttf" },
    .{ .path = "/usr/share/fonts/truetype/noto/NotoSansAdlam-Regular.ttf" },
};

const meetei_mayek_candidates = [_]CandidatePath{
    .{ .path = "/System/Library/Fonts/Supplemental/NotoSansMeeteiMayek-Regular.ttf" },
    .{ .path = "/usr/share/fonts/truetype/noto/NotoSansMeeteiMayek-Regular.ttf" },
};

const yi_candidates = [_]CandidatePath{
    .{ .path = "/System/Library/Fonts/Supplemental/NotoSansYi-Regular.ttf" },
    .{ .path = "/usr/share/fonts/truetype/noto/NotoSansYi-Regular.ttf" },
    .{ .path = "C:\\Windows\\Fonts\\Microsoft Yi Baiti.ttf" },
};

const last_resort_candidates = [_]CandidatePath{
    .{ .path = "/System/Library/Fonts/LastResort.otf" },
    .{ .path = "C:\\Windows\\Fonts\\seguisym.ttf" },
    .{ .path = "/usr/share/fonts/truetype/noto/NotoSansSymbols2-Regular.ttf" },
    .{ .path = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf" },
};

test "role candidates keep CJK language face indexes" {
    const ja = forRoleCandidates(.cjk, "ja-JP", 400, .normal);
    try std.testing.expectEqual(@as(u32, 0), ja[0].face_index);
    const ko = forRoleCandidates(.cjk, "ko-KR", 400, .normal);
    try std.testing.expectEqual(@as(u32, 1), ko[0].face_index);
    const sc = forRoleCandidates(.cjk, "zh-Hans", 400, .normal);
    try std.testing.expectEqual(@as(u32, 2), sc[0].face_index);
    const tc = forRoleCandidates(.cjk, "zh-Hant", 400, .normal);
    try std.testing.expectEqual(@as(u32, 3), tc[0].face_index);
    const hk = forRoleCandidates(.cjk, "zh-HK", 400, .normal);
    try std.testing.expectEqual(@as(u32, 4), hk[0].face_index);
}

test "query fallback handles generics and leaves unknown concrete families alone" {
    const ui_query = forQuery(.{ .family = "\"Missing\", sans-serif" });
    try std.testing.expect(ui_query.len != 0);
    const mono_query = forQuery(.{ .family = "ui-monospace" });
    try std.testing.expect(mono_query.len != 0);
    try std.testing.expect(std.mem.indexOf(u8, mono_query[0].path, "Mono") != null);
    try std.testing.expect(forQuery(.{ .family = "serif" }).len != 0);
    try std.testing.expect(forQuery(.{ .family = "math" }).len != 0);
    try std.testing.expect(forQuery(.{ .family = "cursive" }).len != 0);
    try std.testing.expect(forQuery(.{ .family = "fantasy" }).len != 0);
    const unknown = forQuery(.{ .family = "Definitely Missing Family" });
    try std.testing.expectEqual(@as(usize, 0), unknown.len);
    const uncovered = forQuery(.{ .family = "", .required_codepoint = 0x10ffff });
    try std.testing.expect(uncovered.len != 0);
    try std.testing.expectEqualStrings(
        "/System/Library/Fonts/LastResort.otf",
        uncovered[0].path,
    );
    const generic_cjk = forQuery(.{
        .family = "sans-serif",
        .required_codepoint = 0x4e2d,
        .language = "ja-JP",
    });
    try std.testing.expectEqual(@as(u32, 0), generic_cjk[0].face_index);
    const generic_emoji = forQuery(.{
        .family = "sans-serif",
        .required_codepoint = 0x1f600,
    });
    try std.testing.expect(std.mem.indexOf(u8, generic_emoji[0].path, "Emoji") != null);
}

test "codepoint fallback selects CJK and emoji roles" {
    const cjk_query = forQuery(.{ .family = "", .required_codepoint = 0x4e2d, .language = "ja-JP" });
    try std.testing.expectEqual(@as(u32, 0), cjk_query[0].face_index);
    const emoji_query = forQuery(.{ .family = "", .required_codepoint = 0x1f600 });
    try std.testing.expect(std.mem.indexOf(u8, emoji_query[0].path, "Emoji") != null);
}

const std = @import("std");

test "remaining scripts resolve to dedicated fallbacks" {
    const cases = [_]struct { codepoint: u21, path: []const u8 }{
        .{ .codepoint = 0x0710, .path = "/System/Library/Fonts/Supplemental/NotoSansSyriac-Regular.ttf" },
        .{ .codepoint = 0x0780, .path = "/System/Library/Fonts/Supplemental/NotoSansThaana-Regular.ttf" },
        .{ .codepoint = 0x0b15, .path = "/System/Library/Fonts/NotoSansOriya.ttc" },
        .{ .codepoint = 0x0f40, .path = "/System/Library/Fonts/Kailasa.ttc" },
        .{ .codepoint = 0x1820, .path = "/System/Library/Fonts/Supplemental/NotoSansMongolian-Regular.ttf" },
        .{ .codepoint = 0x13a0, .path = "/System/Library/Fonts/Supplemental/PlantagenetCherokee.ttf" },
        .{ .codepoint = 0x1401, .path = "/System/Library/Fonts/Supplemental/EuphemiaCAS.ttc" },
        .{ .codepoint = 0x2d30, .path = "/System/Library/Fonts/Supplemental/NotoSansTifinagh-Regular.otf" },
        .{ .codepoint = 0x1c50, .path = "/System/Library/Fonts/Supplemental/NotoSansOlChiki-Regular.ttf" },
        .{ .codepoint = 0xa980, .path = "/System/Library/Fonts/Supplemental/NotoSansJavanese-Regular.otf" },
        .{ .codepoint = 0x1b80, .path = "/System/Library/Fonts/Supplemental/NotoSansSundanese-Regular.ttf" },
        .{ .codepoint = 0x1b00, .path = "/System/Library/Fonts/Supplemental/NotoSerifBalinese-Regular.ttf" },
        .{ .codepoint = 0x1bc0, .path = "/System/Library/Fonts/Supplemental/NotoSansBatak-Regular.ttf" },
        .{ .codepoint = 0x1c00, .path = "/System/Library/Fonts/Supplemental/NotoSansLepcha-Regular.ttf" },
        .{ .codepoint = 0xa500, .path = "/System/Library/Fonts/Supplemental/NotoSansVai-Regular.ttf" },
        .{ .codepoint = 0xa6a0, .path = "/System/Library/Fonts/Supplemental/NotoSansBamum-Regular.ttf" },
        .{ .codepoint = 0x1e900, .path = "/System/Library/Fonts/Supplemental/NotoSansAdlam-Regular.ttf" },
        .{ .codepoint = 0xabc0, .path = "/System/Library/Fonts/Supplemental/NotoSansMeeteiMayek-Regular.ttf" },
        .{ .codepoint = 0xa000, .path = "/System/Library/Fonts/Supplemental/NotoSansYi-Regular.ttf" },
    };
    for (cases) |case| {
        const candidates = forQuery(.{
            .family = "",
            .required_codepoint = case.codepoint,
        });
        try std.testing.expect(candidates.len > 0);
        try std.testing.expectEqualStrings(case.path, candidates[0].path);
    }
}

test "unknown codepoints use the platform last-resort font" {
    const candidates = forQuery(.{
        .family = "",
        .required_codepoint = 0x10fff0,
    });
    try std.testing.expect(candidates.len > 0);
    try std.testing.expectEqualStrings(
        "/System/Library/Fonts/LastResort.otf",
        candidates[0].path,
    );
}
