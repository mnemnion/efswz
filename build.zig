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
    "deps/efsw/src/efsw/platform/posix/FileSystemImpl.cpp",
    "deps/efsw/src/efsw/platform/posix/SystemImpl.cpp",
};

const efsw_macos_sources = &.{
    "deps/efsw/src/efsw/FileWatcherFSEvents.cpp",
    "deps/efsw/src/efsw/FileWatcherKqueue.cpp",
    "deps/efsw/src/efsw/WatcherFSEvents.cpp",
    "deps/efsw/src/efsw/WatcherKqueue.cpp",
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
    efsw.linkLibCpp();
    efsw.addIncludePath(b.path("deps/efsw/include"));
    efsw.addIncludePath(b.path("deps/efsw/src"));
    efsw.addCSourceFiles(.{
        .files = efsw_common_sources,
        .flags = &.{
            "-std=c++11",
            "-fPIC",
            "-Wall",
            "-Wno-long-long",
        },
    });

    switch (target_query.os.tag) {
        .macos => {
            efsw.addCSourceFiles(.{
                .files = efsw_macos_sources,
                .flags = &.{
                    "-std=c++11",
                    "-fPIC",
                    "-Wall",
                    "-Wno-long-long",
                },
            });
            efsw.linkFramework("CoreFoundation");
            efsw.linkFramework("CoreServices");
        },
        else => @panic("efswz currently only supports building efsw on macOS"),
    }

    const efswz_mod = b.addModule("efswz", .{
        .root_source_file = b.path("src/efswz.zig"),
        .target = target,
        .optimize = optimize,
    });
    efswz_mod.addIncludePath(b.path("deps/efsw/include"));
    efswz_mod.linkLibrary(efsw);

    const test_filters = b.option(
        []const []const u8,
        "test-filter",
        "Skip tests that do not match any filter",
    ) orelse &[0][]const u8{};

    const module_unit_tests = b.addTest(.{
        .root_module = efswz_mod,
        .filters = test_filters,
    });
    module_unit_tests.linkLibrary(efsw);

    const run_module_unit_tests = b.addRunArtifact(module_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_module_unit_tests.step);

    const run_kcov = b.addSystemCommand(&.{
        "kcov",
        "--clean",
        "--exclude-line=unreachable,expect(false),@panic,kcov-defer-error,kcov-test-cleanup",
    });
    run_kcov.addPrefixedDirectoryArg("--include-pattern=", b.path("src"));
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
