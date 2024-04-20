const std = @import("std");

pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardOptimizeOption(.{});

    const aro = b.dependency("aro", .{
        .target = target,
        .optimize = mode,
    });
    const aro_module = aro.module("aro");
    const resinator = b.addModule("resinator", .{
        .root_source_file = .{ .path = "src/resinator.zig" },
        .imports = &.{
            .{ .name = "aro", .module = aro_module },
        },
    });

    const exe = b.addExecutable(.{
        .name = "resinator",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = mode,
    });
    exe.root_module.addImport("aro", aro_module);
    b.installArtifact(exe);

    const test_filter = b.option([]const u8, "test-filter", "Skip tests that do not match filter");
    const exe_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/resinator.zig" },
        .target = target,
        .optimize = mode,
        .filter = test_filter,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const reference_tests = b.addTest(.{
        .name = "reference",
        .root_source_file = .{ .path = "test/reference.zig" },
        .target = target,
        .optimize = mode,
        .filter = test_filter,
    });
    reference_tests.root_module.addImport("resinator", resinator);
    const run_reference_tests = b.addRunArtifact(reference_tests);

    const parser_tests = b.addTest(.{
        .name = "parse",
        .root_source_file = .{ .path = "test/parse.zig" },
        .target = target,
        .optimize = mode,
        .filter = test_filter,
    });
    parser_tests.root_module.addImport("resinator", resinator);
    const run_parser_tests = b.addRunArtifact(parser_tests);

    const compiler_tests = b.addTest(.{
        .name = "compile",
        .root_source_file = .{ .path = "test/compile.zig" },
        .target = target,
        .optimize = mode,
        .filter = test_filter,
    });
    compiler_tests.root_module.addImport("resinator", resinator);
    const run_compiler_tests = b.addRunArtifact(compiler_tests);

    const cli_test_options = b.addOptions();
    cli_test_options.addOptionPath("cli_exe_path", exe.getEmittedBin());
    const cli_tests = b.addTest(.{
        .name = "cli",
        .root_source_file = .{ .path = "test/cli.zig" },
    });
    cli_tests.root_module.addOptions("build_options", cli_test_options);
    const run_cli_tests = b.addRunArtifact(cli_tests);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_reference_tests.step);
    test_step.dependOn(&run_parser_tests.step);
    test_step.dependOn(&run_compiler_tests.step);
    test_step.dependOn(&run_cli_tests.step);

    // TODO: coverage across all test steps?
    const coverage = b.option(bool, "test-coverage", "Generate test coverage") orelse false;
    if (coverage) {
        // with kcov
        exe_tests.setExecCmd(&[_]?[]const u8{
            "kcov",
            //"--path-strip-level=3", // any kcov flags can be specified here
            "--include-pattern=resinator",
            "kcov-output", // output dir for kcov
            null, // to get zig to use the --test-cmd-bin flag
        });
    }

    const fuzzy_max_iterations = b.option(u64, "fuzzy-iterations", "The max iterations for fuzzy tests (default: 1000)") orelse 1000;

    const test_options = b.addOptions();
    test_options.addOption(u64, "max_iterations", fuzzy_max_iterations);

    const all_fuzzy_tests_step = b.step("test_fuzzy", "Run all fuzz/property-testing-like tests with a max number of iterations for each");
    _ = addFuzzyTest(b, "numbers", mode, target, resinator, all_fuzzy_tests_step, test_options);
    _ = addFuzzyTest(b, "number_expressions", mode, target, resinator, all_fuzzy_tests_step, test_options);
    _ = addFuzzyTest(b, "ascii_strings", mode, target, resinator, all_fuzzy_tests_step, test_options);
    _ = addFuzzyTest(b, "numeric_types", mode, target, resinator, all_fuzzy_tests_step, test_options);
    _ = addFuzzyTest(b, "common_resource_attributes", mode, target, resinator, all_fuzzy_tests_step, test_options);
    _ = addFuzzyTest(b, "raw_data", mode, target, resinator, all_fuzzy_tests_step, test_options);
    _ = addFuzzyTest(b, "name_or_ordinal", mode, target, resinator, all_fuzzy_tests_step, test_options);
    _ = addFuzzyTest(b, "code_pages", mode, target, resinator, all_fuzzy_tests_step, test_options);
    _ = addFuzzyTest(b, "icons", mode, target, resinator, all_fuzzy_tests_step, test_options);
    _ = addFuzzyTest(b, "bitmaps", mode, target, resinator, all_fuzzy_tests_step, test_options);
    _ = addFuzzyTest(b, "stringtable", mode, target, resinator, all_fuzzy_tests_step, test_options);
    _ = addFuzzyTest(b, "fonts", mode, target, resinator, all_fuzzy_tests_step, test_options);
    _ = addFuzzyTest(b, "dlginclude", mode, target, resinator, all_fuzzy_tests_step, test_options);
    _ = addFuzzyTest(b, "strings", mode, target, resinator, all_fuzzy_tests_step, test_options);
    _ = addFuzzyTest(b, "accelerators", mode, target, resinator, all_fuzzy_tests_step, test_options);

    _ = addFuzzer(b, "fuzz_rc", &.{}, resinator, target);

    const fuzz_winafl_exe = b.addExecutable(.{
        .name = "fuzz_winafl",
        .root_source_file = .{ .path = "test/fuzz_winafl.zig" },
        .target = target,
        .optimize = mode,
    });
    fuzz_winafl_exe.root_module.addImport("resinator", resinator);
    const fuzz_winafl_compile = b.step("fuzz_winafl", "Build/install fuzz_winafl exe");
    const install_fuzz_winafl = b.addInstallArtifact(fuzz_winafl_exe, .{});
    fuzz_winafl_compile.dependOn(&install_fuzz_winafl.step);

    // release step
    {
        const release_step = b.step("release", "Build release binaries for all supported targets");
        const release_targets = &[_]std.Target.Query{
            .{ .cpu_arch = .x86_64, .os_tag = .macos },
            .{ .cpu_arch = .aarch64, .os_tag = .macos },
            .{ .cpu_arch = .aarch64, .os_tag = .linux },
            .{ .cpu_arch = .x86_64, .os_tag = .linux },
            .{ .cpu_arch = .x86_64, .os_tag = .windows },
        };
        for (release_targets) |release_target| {
            const resolved_release_target = b.resolveTargetQuery(release_target);
            const release_exe = b.addExecutable(.{
                .name = "resinator",
                .root_source_file = .{ .path = "src/main.zig" },
                .target = resolved_release_target,
                .optimize = .ReleaseSmall,
                .single_threaded = true,
                .strip = true,
            });
            release_exe.root_module.addImport("aro", aro_module);

            const triple = release_target.zigTriple(b.allocator) catch unreachable;
            const install_dir = b.pathJoin(&.{ "release", triple });
            const release_install = b.addInstallArtifact(
                release_exe,
                .{ .dest_dir = .{
                    .override = .{ .custom = install_dir },
                } },
            );
            release_step.dependOn(&release_install.step);
        }
    }
}

fn addFuzzyTest(
    b: *std.Build,
    comptime name: []const u8,
    mode: std.builtin.Mode,
    target: std.Build.ResolvedTarget,
    resinator: *std.Build.Module,
    all_fuzzy_tests_step: *std.Build.Step,
    fuzzy_options: *std.Build.Step.Options,
) *std.Build.Step.Compile {
    var test_step = b.addTest(.{
        .root_source_file = .{ .path = "test/fuzzy_" ++ name ++ ".zig" },
        .target = target,
        .optimize = mode,
    });
    test_step.root_module.addImport("resinator", resinator);
    test_step.root_module.addOptions("fuzzy_options", fuzzy_options);

    const run_test = b.addRunArtifact(test_step);

    var test_run_step = b.step("test_fuzzy_" ++ name, "Some fuzz/property-testing-like tests for " ++ name);
    test_run_step.dependOn(&run_test.step);

    all_fuzzy_tests_step.dependOn(test_run_step);

    return test_step;
}

fn addFuzzer(
    b: *std.Build,
    comptime name: []const u8,
    afl_clang_args: []const []const u8,
    resinator: *std.Build.Module,
    target: std.Build.ResolvedTarget,
) FuzzerSteps {
    // The library
    const fuzz_lib = b.addStaticLibrary(.{
        .name = name ++ "-lib",
        .root_source_file = .{ .path = "test/" ++ name ++ ".zig" },
        .target = target,
        .optimize = .Debug,
    });
    fuzz_lib.root_module.addImport("resinator", resinator);
    fuzz_lib.want_lto = true;
    fuzz_lib.bundle_compiler_rt = true;
    fuzz_lib.root_module.pic = true;

    // Setup the output name
    const fuzz_executable_name = name;
    const fuzz_exe_path = std.fs.path.join(b.allocator, &.{ b.cache_root.path.?, fuzz_executable_name }) catch unreachable;

    // We want `afl-clang-lto -o path/to/output path/to/library`
    const fuzz_compile = b.addSystemCommand(&.{ "afl-clang-lto", "-o", fuzz_exe_path });
    // Add the path to the library file to afl-clang-lto's args
    fuzz_compile.addArtifactArg(fuzz_lib);
    // Custom args
    fuzz_compile.addArgs(afl_clang_args);

    // Install the cached output to the install 'bin' path
    const fuzz_install = b.addInstallBinFile(.{ .path = fuzz_exe_path }, fuzz_executable_name);
    fuzz_install.step.dependOn(&fuzz_compile.step);

    // Add a top-level step that compiles and installs the fuzz executable
    const fuzz_compile_run = b.step(name, "Build executable for fuzz testing '" ++ name ++ "' using afl-clang-lto");
    fuzz_compile_run.dependOn(&fuzz_compile.step);
    fuzz_compile_run.dependOn(&fuzz_install.step);

    // Compile a companion exe for debugging crashes
    const fuzz_debug_exe = b.addExecutable(.{
        .name = name ++ "-debug",
        .root_source_file = .{ .path = "test/" ++ name ++ ".zig" },
        .target = target,
        .optimize = .Debug,
    });
    fuzz_debug_exe.root_module.addImport("resinator", resinator);

    // Only install fuzz-debug when the fuzz step is run
    const install_fuzz_debug_exe = b.addInstallArtifact(fuzz_debug_exe, .{});
    fuzz_compile_run.dependOn(&install_fuzz_debug_exe.step);

    return FuzzerSteps{
        .lib = fuzz_lib,
        .debug_exe = fuzz_debug_exe,
    };
}

const FuzzerSteps = struct {
    lib: *std.Build.Step.Compile,
    debug_exe: *std.Build.Step.Compile,

    pub fn libExes(self: *const FuzzerSteps) [2]*std.Build.Step.Compile {
        return [_]*std.Build.Step.Compile{ self.lib, self.debug_exe };
    }
};
