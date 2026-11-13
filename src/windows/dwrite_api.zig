//! Narrow DirectWrite v1 COM ABI used by the system-font provider.

const std = @import("std");
const win = std.os.windows;

pub const HRESULT = i32;
pub const BOOL = i32;
pub const GUID = win.GUID;

pub const Factory = extern struct { lpVtbl: *const FactoryVTable };
pub const FontCollection = extern struct { lpVtbl: *const FontCollectionVTable };
pub const FontFamily = extern struct { lpVtbl: *const FontFamilyVTable };
pub const Font = extern struct { lpVtbl: *const FontVTable };
pub const FontFace = extern struct { lpVtbl: *const FontFaceVTable };
pub const FontFile = extern struct { lpVtbl: *const FontFileVTable };
pub const FontFileLoader = extern struct { lpVtbl: *const FontFileLoaderVTable };
pub const LocalFontFileLoader = extern struct { lpVtbl: *const LocalFontFileLoaderVTable };
pub const LocalizedStrings = extern struct { lpVtbl: *const LocalizedStringsVTable };

const QueryInterfaceFn = *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT;
const AddRefFn = *const fn (*anyopaque) callconv(.winapi) u32;
const ReleaseFn = *const fn (*anyopaque) callconv(.winapi) u32;

pub const FactoryVTable = extern struct {
    QueryInterface: QueryInterfaceFn,
    AddRef: AddRefFn,
    Release: ReleaseFn,
    GetSystemFontCollection: *const fn (*Factory, *?*FontCollection, BOOL) callconv(.winapi) HRESULT,
    CreateCustomFontCollection: *const anyopaque,
    RegisterFontCollectionLoader: *const anyopaque,
    UnregisterFontCollectionLoader: *const anyopaque,
    CreateFontFileReference: *const anyopaque,
    CreateCustomFontFileReference: *const anyopaque,
    CreateFontFace: *const anyopaque,
    CreateRenderingParams: *const anyopaque,
    CreateMonitorRenderingParams: *const anyopaque,
    CreateCustomRenderingParams: *const anyopaque,
    RegisterFontFileLoader: *const anyopaque,
    UnregisterFontFileLoader: *const anyopaque,
    CreateTextFormat: *const anyopaque,
    CreateTypography: *const anyopaque,
    GetGdiInterop: *const anyopaque,
    CreateTextLayout: *const anyopaque,
    CreateGdiCompatibleTextLayout: *const anyopaque,
    CreateEllipsisTrimmingSign: *const anyopaque,
    CreateTextAnalyzer: *const anyopaque,
    CreateNumberSubstitution: *const anyopaque,
    CreateGlyphRunAnalysis: *const anyopaque,
};

pub const FontCollectionVTable = extern struct {
    QueryInterface: QueryInterfaceFn,
    AddRef: AddRefFn,
    Release: ReleaseFn,
    GetFontFamilyCount: *const fn (*FontCollection) callconv(.winapi) u32,
    GetFontFamily: *const fn (*FontCollection, u32, *?*FontFamily) callconv(.winapi) HRESULT,
    FindFamilyName: *const fn (*FontCollection, [*:0]const u16, *u32, *BOOL) callconv(.winapi) HRESULT,
    GetFontFromFontFace: *const anyopaque,
};

pub const FontFamilyVTable = extern struct {
    QueryInterface: QueryInterfaceFn,
    AddRef: AddRefFn,
    Release: ReleaseFn,
    GetFontCollection: *const anyopaque,
    GetFontCount: *const fn (*FontFamily) callconv(.winapi) u32,
    GetFont: *const fn (*FontFamily, u32, *?*Font) callconv(.winapi) HRESULT,
    GetFamilyNames: *const fn (*FontFamily, *?*LocalizedStrings) callconv(.winapi) HRESULT,
    GetFirstMatchingFont: *const fn (*FontFamily, u32, u32, u32, *?*Font) callconv(.winapi) HRESULT,
    GetMatchingFonts: *const anyopaque,
};

pub const FontVTable = extern struct {
    QueryInterface: QueryInterfaceFn,
    AddRef: AddRefFn,
    Release: ReleaseFn,
    GetFontFamily: *const anyopaque,
    GetWeight: *const anyopaque,
    GetStretch: *const anyopaque,
    GetStyle: *const anyopaque,
    IsSymbolFont: *const anyopaque,
    GetFaceNames: *const anyopaque,
    GetInformationalStrings: *const fn (*Font, u32, *?*LocalizedStrings, *BOOL) callconv(.winapi) HRESULT,
    GetSimulations: *const anyopaque,
    GetMetrics: *const anyopaque,
    HasCharacter: *const fn (*Font, u32, *BOOL) callconv(.winapi) HRESULT,
    CreateFontFace: *const fn (*Font, *?*FontFace) callconv(.winapi) HRESULT,
};

pub const FontFaceVTable = extern struct {
    QueryInterface: QueryInterfaceFn,
    AddRef: AddRefFn,
    Release: ReleaseFn,
    GetType: *const anyopaque,
    GetFiles: *const fn (*FontFace, *u32, ?[*]*FontFile) callconv(.winapi) HRESULT,
    GetIndex: *const fn (*FontFace) callconv(.winapi) u32,
    GetSimulations: *const anyopaque,
    IsSymbolFont: *const anyopaque,
    GetMetrics: *const anyopaque,
    GetGlyphCount: *const anyopaque,
    GetDesignGlyphMetrics: *const anyopaque,
    GetGlyphIndices: *const anyopaque,
    TryGetFontTable: *const anyopaque,
    ReleaseFontTable: *const anyopaque,
    GetGlyphRunOutline: *const anyopaque,
    GetRecommendedRenderingMode: *const anyopaque,
    GetGdiCompatibleMetrics: *const anyopaque,
    GetGdiCompatibleGlyphMetrics: *const anyopaque,
};

pub const FontFileVTable = extern struct {
    QueryInterface: QueryInterfaceFn,
    AddRef: AddRefFn,
    Release: ReleaseFn,
    GetReferenceKey: *const fn (*FontFile, *?*const anyopaque, *u32) callconv(.winapi) HRESULT,
    GetLoader: *const fn (*FontFile, *?*FontFileLoader) callconv(.winapi) HRESULT,
    Analyze: *const anyopaque,
};

pub const FontFileLoaderVTable = extern struct {
    QueryInterface: QueryInterfaceFn,
    AddRef: AddRefFn,
    Release: ReleaseFn,
    CreateStreamFromKey: *const anyopaque,
};

pub const LocalFontFileLoaderVTable = extern struct {
    QueryInterface: QueryInterfaceFn,
    AddRef: AddRefFn,
    Release: ReleaseFn,
    CreateStreamFromKey: *const anyopaque,
    GetFilePathLengthFromKey: *const fn (*LocalFontFileLoader, *const anyopaque, u32, *u32) callconv(.winapi) HRESULT,
    GetFilePathFromKey: *const fn (*LocalFontFileLoader, *const anyopaque, u32, [*]u16, u32) callconv(.winapi) HRESULT,
    GetLastWriteTimeFromKey: *const anyopaque,
};

pub const LocalizedStringsVTable = extern struct {
    QueryInterface: QueryInterfaceFn,
    AddRef: AddRefFn,
    Release: ReleaseFn,
    GetCount: *const fn (*LocalizedStrings) callconv(.winapi) u32,
    FindLocaleName: *const anyopaque,
    GetLocaleNameLength: *const anyopaque,
    GetLocaleName: *const anyopaque,
    GetStringLength: *const fn (*LocalizedStrings, u32, *u32) callconv(.winapi) HRESULT,
    GetString: *const fn (*LocalizedStrings, u32, [*]u16, u32) callconv(.winapi) HRESULT,
};

pub const FaceFile = struct {
    path: []u8,
    face_index: u32,

    pub fn deinit(self: *FaceFile, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        self.* = undefined;
    }
};

pub const iid_factory = GUID.parse("{B859EE5A-D838-4B5B-A2E8-1ADC7D93DB48}");
const iid_local_font_file_loader = GUID.parse("{B2D9F3EC-C9FE-4A11-A2EC-D86208F7C0A2}");

extern "dwrite" fn DWriteCreateFactory(
    factory_type: u32,
    iid: *const GUID,
    factory: *?*anyopaque,
) callconv(.winapi) HRESULT;

pub fn createFactory() ?*Factory {
    var raw: ?*anyopaque = null;
    if (failed(DWriteCreateFactory(0, &iid_factory, &raw))) return null;
    return @ptrCast(@alignCast(raw orelse return null));
}

pub fn systemCollection(factory: *Factory, check_updates: bool) ?*FontCollection {
    var collection: ?*FontCollection = null;
    if (failed(factory.lpVtbl.GetSystemFontCollection(
        factory,
        &collection,
        @intFromBool(check_updates),
    ))) return null;
    return collection;
}

pub fn familyAt(collection: *FontCollection, index: u32) ?*FontFamily {
    var family: ?*FontFamily = null;
    if (failed(collection.lpVtbl.GetFontFamily(collection, index, &family))) return null;
    return family;
}

pub fn findFamily(
    allocator: std.mem.Allocator,
    collection: *FontCollection,
    name: []const u8,
) !?*FontFamily {
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(allocator, name);
    defer allocator.free(wide);
    var index: u32 = 0;
    var exists: BOOL = 0;
    if (failed(collection.lpVtbl.FindFamilyName(
        collection,
        wide.ptr,
        &index,
        &exists,
    )) or exists == 0) return null;
    return familyAt(collection, index);
}

pub fn matchingFont(
    family: *FontFamily,
    weight: u32,
    stretch: u32,
    style: u32,
) ?*Font {
    var font: ?*Font = null;
    if (failed(family.lpVtbl.GetFirstMatchingFont(
        family,
        weight,
        stretch,
        style,
        &font,
    ))) return null;
    return font;
}

pub fn hasCharacter(font: *Font, codepoint: u21) bool {
    var exists: BOOL = 0;
    return !failed(font.lpVtbl.HasCharacter(font, codepoint, &exists)) and
        exists != 0;
}

pub fn localizedFirst(
    allocator: std.mem.Allocator,
    strings: *LocalizedStrings,
) !?[]u8 {
    if (strings.lpVtbl.GetCount(strings) == 0) return null;
    var length: u32 = 0;
    if (failed(strings.lpVtbl.GetStringLength(strings, 0, &length))) return null;
    const wide = try allocator.alloc(u16, @as(usize, length) + 1);
    defer allocator.free(wide);
    if (failed(strings.lpVtbl.GetString(strings, 0, wide.ptr, length + 1))) return null;
    return try std.unicode.utf16LeToUtf8Alloc(allocator, wide[0..length]);
}

pub fn familyName(allocator: std.mem.Allocator, family: *FontFamily) !?[]u8 {
    var strings: ?*LocalizedStrings = null;
    if (failed(family.lpVtbl.GetFamilyNames(family, &strings))) return null;
    const owned = strings orelse return null;
    defer release(owned);
    return try localizedFirst(allocator, owned);
}

pub fn postscriptName(allocator: std.mem.Allocator, font: *Font) !?[]u8 {
    var strings: ?*LocalizedStrings = null;
    var exists: BOOL = 0;
    // DWRITE_INFORMATIONAL_STRING_POSTSCRIPT_NAME
    if (failed(font.lpVtbl.GetInformationalStrings(
        font,
        17,
        &strings,
        &exists,
    )) or exists == 0) return null;
    const owned = strings orelse return null;
    defer release(owned);
    return try localizedFirst(allocator, owned);
}

pub fn faceFile(allocator: std.mem.Allocator, font: *Font) !?FaceFile {
    var face: ?*FontFace = null;
    if (failed(font.lpVtbl.CreateFontFace(font, &face))) return null;
    const owned_face = face orelse return null;
    defer release(owned_face);
    var count: u32 = 0;
    if (failed(owned_face.lpVtbl.GetFiles(owned_face, &count, null)) or count == 0) {
        return null;
    }
    const files = try allocator.alloc(*FontFile, count);
    defer allocator.free(files);
    if (failed(owned_face.lpVtbl.GetFiles(owned_face, &count, files.ptr))) return null;
    defer for (files[0..count]) |file| release(file);
    for (files[0..count]) |file| {
        if (try localFilePath(allocator, file)) |path| {
            return .{
                .path = path,
                .face_index = owned_face.lpVtbl.GetIndex(owned_face),
            };
        }
    }
    return null;
}

fn localFilePath(allocator: std.mem.Allocator, file: *FontFile) !?[]u8 {
    var key: ?*const anyopaque = null;
    var key_size: u32 = 0;
    if (failed(file.lpVtbl.GetReferenceKey(file, &key, &key_size))) return null;
    const reference_key = key orelse return null;
    var loader: ?*FontFileLoader = null;
    if (failed(file.lpVtbl.GetLoader(file, &loader))) return null;
    const owned_loader = loader orelse return null;
    defer release(owned_loader);
    var local_raw: ?*anyopaque = null;
    if (failed(owned_loader.lpVtbl.QueryInterface(
        @ptrCast(owned_loader),
        &iid_local_font_file_loader,
        &local_raw,
    ))) return null;
    const local: *LocalFontFileLoader = @ptrCast(@alignCast(local_raw orelse return null));
    defer release(local);
    var length: u32 = 0;
    if (failed(local.lpVtbl.GetFilePathLengthFromKey(
        local,
        reference_key,
        key_size,
        &length,
    ))) return null;
    const wide = try allocator.alloc(u16, @as(usize, length) + 1);
    defer allocator.free(wide);
    if (failed(local.lpVtbl.GetFilePathFromKey(
        local,
        reference_key,
        key_size,
        wide.ptr,
        length + 1,
    ))) return null;
    return try std.unicode.utf16LeToUtf8Alloc(allocator, wide[0..length]);
}

pub fn release(value: anytype) void {
    const raw: *anyopaque = @ptrCast(value);
    const unknown: *const extern struct { lpVtbl: *const extern struct {
        QueryInterface: QueryInterfaceFn,
        AddRef: AddRefFn,
        Release: ReleaseFn,
    } } = @ptrCast(@alignCast(raw));
    _ = unknown.lpVtbl.Release(raw);
}

pub fn failed(result: HRESULT) bool {
    return result < 0;
}
