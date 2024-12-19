const std = @import("std");
const testing = std.testing;
const builtin = @import("builtin");
const linkage: std.builtin.GlobalLinkage = if (builtin.is_test) .internal else .weak;
const panic = @import("common.zig").panic;

const need_isPlatformVersionAtLeast = builtin.os.tag.isDarwin();
const have_availability_version_check = builtin.os.tag.isDarwin() and
    builtin.os.version_range.semver.min.order(.{ .major = 11, .minor = 0, .patch = 0 }).compare(.gte);

comptime {
    if (need_isPlatformVersionAtLeast) {
        @export(__isPlatformVersionAtLeast, .{ .name = "__isPlatformVersionAtLeast", .linkage = linkage });
    }
}

// Ported from llvm-project 13.0.0 d7b669b3a30345cfcdb2fde2af6f48aa4b94845d
//
// https://github.com/llvm/llvm-project/blob/llvmorg-13.0.0/compiler-rt/lib/builtins/os_version_check.c

// The compiler generates calls to __isPlatformVersionAtLeast() when Objective-C's @available
// function is invoked.
//
// Old versions of clang would instead emit calls to __isOSVersionAtLeast(), which is still
// supported in clang's compiler-rt implementation today in case anyone tries to link an object file
// produced with an old clang version. This requires dynamically loading frameworks, parsing a
// system plist file, and generally adds a fair amount of complexity to the implementation and so
// our implementation differs by simply removing that backwards compatability support. We only use
// the newer codepath, which merely calls out to the Darwin _availability_version_check API which is
// available on macOS 10.15+, iOS 13+, tvOS 13+ and watchOS 6+.

const __isPlatformVersionAtLeast = if (have_availability_version_check) struct {
    inline fn constructVersion(major: u32, minor: u32, subminor: u32) u32 {
        return ((major & 0xffff) << 16) | ((minor & 0xff) << 8) | (subminor & 0xff);
    }

    // Darwin-only
    fn __isPlatformVersionAtLeast(platform: u32, major: u32, minor: u32, subminor: u32) callconv(.C) i32 {
        const build_version = dyld_build_version_t{
            .platform = platform,
            .version = constructVersion(major, minor, subminor),
        };
        return @intFromBool(_availability_version_check(1, &[_]dyld_build_version_t{build_version}));
    }

    // _availability_version_check darwin API support.
    const dyld_platform_t = u32;
    const dyld_build_version_t = extern struct {
        platform: dyld_platform_t,
        version: u32,
    };
    // Darwin-only
    extern "c" fn _availability_version_check(count: u32, versions: [*c]const dyld_build_version_t) bool;
}.__isPlatformVersionAtLeast
else
// if we don't have availability API, then we have to fall back to checking the kernel version
if (need_isPlatformVersionAtLeast) struct {
    // NB: this path is actually more reliable even for higher min targets since the above will incorrectly
    //     identify availability if a binary is loaded in a system which is below the min version
    //     which is actually possible
    fn __isPlatformVersionAtLeast(_: u32, major: u32, minor: u32, subminor: u32) callconv(.C) i32 {
        // Note: we only implement this for the macOS platform
        var ver: [24:0]u8 = undefined;
        var len: usize = 24;

        // the syscall shouldn't fail, but just in case deny everything
        if (sysctlbyname("kern.osrelease", &ver, &len, null, 0) != 0) return 0;

        // gives e.g.: "17.7.0" -> macOS 10.13.7; "24.1.0" -> macOS 15.1
        // we have to parse out the parts and convert them to the macOS versions
        var vmaj: u8 = 0;
        var vmin: u8 = 0;
        var vsub: u8 = 0;
        if (ver[0] >= '0' and ver[0] <= '9') {
            var vi: u8 = 1;
            vmaj = ver[0] - '0';
            if (ver[1] >= '0' and ver[1] <= '9') {
                vmaj = vmaj * 10 + (ver[1] - '0');
                vi = 2;
            }
            if (ver[vi] == '.' and ver[vi + 1] >= '0' and ver[vi + 1] <= '9') {
                vmin = ver[vi + 1] - '0';
                if (ver[vi + 2] >= '0' and ver[vi + 2] <= '9')
                    vmin = vmin * 10 + (ver[vi + 2] - '0');
            }
            // NB: kernels generally don't bother with subminor versions
        }

        if (vmaj < 20) { // OS X (from 10.1.1 -> Darwin 5.1 to 10.15.6 -> Darwin 19.6.0)
            vsub = vmin;
            vmin = vmaj - 4;
            vmaj = 10;
        } else { // macOS 11+ (note that vsub doesn't always match)
            vmaj = vmaj - 9;
        }

        // compare the obtained versions with the constraints
        if (vmaj > major or (vmaj == major and (vmin > minor or (vmin == minor and vsub >= subminor))))
            return 1;

        return 0;
    }
    // we want to avoid further std deps so use direct decl
    extern "c" fn sysctlbyname(name: [*:0]const u8, oldp: ?*anyopaque, oldlenp: ?*usize, newp: ?*anyopaque, newlen: usize) c_int;
}.__isPlatformVersionAtLeast else struct {};

test "isPlatformVersionAtLeast" {
    if (!have_availability_version_check) return error.SkipZigTest;

    // Note: this test depends on the actual host OS version since it is merely calling into the
    // native Darwin API.
    const macos_platform_constant = 1;
    try testing.expect(__isPlatformVersionAtLeast(macos_platform_constant, 10, 0, 15) == 1);
    try testing.expect(__isPlatformVersionAtLeast(macos_platform_constant, 99, 0, 0) == 0);
}
