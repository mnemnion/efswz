const std = @import("std");

const efsw_common_sources = &.{
    "deps/efsw/src/efsw/Debug.cpp",
    "deps/efsw/src/efsw/DirectorySnapshot.cpp",
    "deps/efsw/src/efsw/DirectorySnapshotDiff.cpp",
    "deps/efsw/src/efsw/DirWatcherGeneric.cpp",
    "deps/efsw/src/efsw/FileInfo.cpp",
    "deps/efsw/src/efsw/FileSystem.cpp",
    "deps/efsw/src/efsw/FileWatcher.cpp",
    "deps/efsw/src/efsw/FileWatcherCWrapper.cpp",
    "deps/efsw/src/efsw/FileWatcherGeneric.cpp",
    "deps/efsw/src/efsw/FileWatcherImpl.cpp",
    "deps/efsw/src/efsw/Log.cpp",
    "deps/efsw/src/efsw/String.cpp",
    "deps/efsw/src/efsw/System.cpp",
    "deps/efsw/src/efsw/Watcher.cpp",
    "deps/efsw/src/efsw/WatcherGeneric.cpp",
};

const efsw_posix_platform_sources = &.{
    "deps/efsw/src/efsw/platform/posix/FileSystemImpl.cpp",
    "deps/efsw/src/efsw/platform/posix/SystemImpl.cpp",
};

const efsw_windows_platform_sources = &.{
    "deps/efsw/src/efsw/platform/win/FileSystemImpl.cpp",
    "deps/efsw/src/efsw/platform/win/SystemImpl.cpp",
};

const efsw_macos_sources = &.{
    "deps/efsw/src/efsw/FileWatcherFSEvents.cpp",
    "deps/efsw/src/efsw/FileWatcherKqueue.cpp",
    "deps/efsw/src/efsw/WatcherFSEvents.cpp",
    "deps/efsw/src/efsw/WatcherKqueue.cpp",
};

const efsw_windows_sources = &.{
    "deps/efsw/src/efsw/FileWatcherWin32.cpp",
    "deps/efsw/src/efsw/WatcherWin32.cpp",
};

const efsw_inotify_sources = &.{
    "deps/efsw/src/efsw/FileWatcherInotify.cpp",
    "deps/efsw/src/efsw/WatcherInotify.cpp",
};

const efsw_kqueue_sources = &.{
    "deps/efsw/src/efsw/FileWatcherKqueue.cpp",
    "deps/efsw/src/efsw/WatcherKqueue.cpp",
};

const cxx_non_msvc_flags = &.{
    "-std=c++11",
    "-fPIC",
    "-Wall",
    "-Wno-long-long",
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const target_query = target.result;

    const efsw = b.addLibrary(.{
        .linkage = .static,
        .name = "efsw",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libcpp = true,
        }),
    });
    efsw.root_module.addIncludePath(b.path("deps/efsw/include"));
    efsw.root_module.addIncludePath(b.path("deps/efsw/src"));
    efsw.root_module.addCSourceFiles(.{
        .files = efsw_common_sources,
        .flags = cxx_non_msvc_flags,
    });

    switch (target_query.os.tag) {
        .macos => {
            efsw.root_module.addCSourceFiles(.{
                .files = efsw_posix_platform_sources,
                .flags = cxx_non_msvc_flags,
            });
            efsw.root_module.addCSourceFiles(.{
                .files = efsw_macos_sources,
                .flags = cxx_non_msvc_flags,
            });
            efsw.root_module.linkFramework("CoreFoundation", .{});
            efsw.root_module.linkFramework("CoreServices", .{});
        },
        .windows => {
            efsw.root_module.addCSourceFiles(.{
                .files = efsw_windows_platform_sources,
                .flags = cxx_non_msvc_flags,
            });
            efsw.root_module.addCSourceFiles(.{
                .files = efsw_windows_sources,
                .flags = cxx_non_msvc_flags,
            });
        },
        .linux => {
            efsw.root_module.addCSourceFiles(.{
                .files = efsw_posix_platform_sources,
                .flags = cxx_non_msvc_flags,
            });
            efsw.root_module.addCSourceFiles(.{
                .files = efsw_inotify_sources,
                .flags = cxx_non_msvc_flags,
            });
            efsw.root_module.linkSystemLibrary("pthread", .{});
        },
        .freebsd, .openbsd, .netbsd, .dragonfly => {
            efsw.root_module.addCSourceFiles(.{
                .files = efsw_posix_platform_sources,
                .flags = cxx_non_msvc_flags,
            });
            efsw.root_module.addCSourceFiles(.{
                .files = efsw_kqueue_sources,
                .flags = cxx_non_msvc_flags,
            });
            efsw.root_module.linkSystemLibrary("pthread", .{});
        },
        else => @panic("efswz does not yet wire an efsw backend for this target OS"),
    }

    const efswz_mod = b.addModule("efswz", .{
        .root_source_file = b.path("src/efswz.zig"),
        .target = target,
        .optimize = optimize,
    });
    const c: @import("translate_c").Translator = .init(b.dependency("translate_c", .{}), .{
        .c_source_file = b.path("deps/efsw/include/efsw/efsw.h"),
        .target = target,
        .optimize = optimize,
    });
    efswz_mod.addImport("efsw_c", c.mod);
    efswz_mod.addIncludePath(b.path("deps/efsw/include"));
    efswz_mod.linkLibrary(efsw);

    const demo_exe = b.addExecutable(.{
        .name = "watch-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/watch-demo.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "efswz", .module = efswz_mod },
            },
        }),
    });
    demo_exe.root_module.linkLibrary(efsw);
    b.installArtifact(demo_exe);

    const run_demo = b.addRunArtifact(demo_exe);
    run_demo.addPassthruArgs();

    const demo_step = b.step("demo", "Build and run the watch demo");
    demo_step.dependOn(&run_demo.step);

    const test_filters = b.option(
        []const []const u8,
        "test-filter",
        "Skip tests that do not match any filter",
    ) orelse &[0][]const u8{};

    const module_unit_tests = b.addTest(.{
        .root_module = efswz_mod,
        .filters = test_filters,
    });
    module_unit_tests.root_module.linkLibrary(efsw);

    const run_module_unit_tests = b.addRunArtifact(module_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_module_unit_tests.step);

    const run_kcov = b.addSystemCommand(&.{
        "kcov",
        "--clean",
        "--exclude-line=unreachable,expect(false),@panic,kcov-defer-error,kcov-test-cleanup,kcov-miss",
    });
    run_kcov.addDirectoryArg2(b.path("src"), .{ .prefix = "--include-pattern=", .make_absolute = true });
    const coverage_output = run_kcov.addOutputDirectoryArg(".");
    run_kcov.addArtifactArg(module_unit_tests);

    run_kcov.enableTestRunnerMode();

    const install_coverage = b.addInstallDirectory(.{
        .source_dir = coverage_output,
        .install_dir = .{ .custom = "coverage" },
        .install_subdir = "",
    });

    const coverage_step = b.step("coverage", "Generate coverage (kcov must be installed)");
    coverage_step.dependOn(&install_coverage.step);
}
