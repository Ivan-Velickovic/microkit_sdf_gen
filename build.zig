const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const dtbzig_dep = b.dependency("dtb.zig", .{});
    const dtb_module = dtbzig_dep.module("dtb");

    const python_include = b.option([]const []const u8, "python-include", "Include directory for Python bindings") orelse &.{};

    const lib = b.addStaticLibrary(.{
        .name = "microkit_sdf_gen",
        .root_source_file = b.path("src/sdf.zig"),
        .target = target,
        .optimize = optimize,
    });

    const sdf_module = b.addModule("sdf", .{
        .root_source_file = b.path("src/mod.zig"),
        .target = target,
        .optimize = optimize,
    });
    sdf_module.addImport("dtb", dtb_module);

    const sdfgen_step = b.step("zig_example", "Exmaples of using Zig bindings");
    const sdfgen = b.addExecutable(.{
        .name = "zig_example",
        .root_source_file = b.path("examples/examples.zig"),
        .target = target,
        .optimize = optimize,
    });

    sdfgen.root_module.addImport("sdf", sdf_module);

    const sdfgen_cmd = b.addRunArtifact(sdfgen);
    if (b.args) |args| {
        sdfgen_cmd.addArgs(args);
    }
    // In case any sDDF configuration files are changed
    _ = try sdfgen_cmd.step.addDirectoryWatchInput(b.path("sddf"));

    sdfgen_step.dependOn(&sdfgen_cmd.step);
    const sdfgen_install = b.addInstallArtifact(sdfgen, .{});
    sdfgen_step.dependOn(&sdfgen_install.step);

    b.installArtifact(lib);

    const modsdf = b.addModule("sdf", .{ .root_source_file = b.path("src/mod.zig") });
    modsdf.addImport("dtb", dtbzig_dep.module("dtb"));

    const csdfgen = b.addStaticLibrary(.{
        .name = "csdfgen",
        .root_source_file = b.path("src/c/c.zig"),
        .target = target,
        .optimize = optimize,
    });
    csdfgen.linkLibC();
    csdfgen.installHeader(b.path("src/c/sdfgen.h"), "sdfgen.h");
    csdfgen.root_module.addImport("sdf", modsdf);
    b.installArtifact(csdfgen);

    const pysdfgen_bin = b.option([]const u8, "pysdfgen-emit", "Build pysdfgen library") orelse "pysdfgen.so";
    const pysdfgen = b.addSharedLibrary(.{
        .name = "pysdfgen",
        .target = target,
        .optimize = optimize,
    });
    pysdfgen.linkLibrary(csdfgen);
    pysdfgen.linker_allow_shlib_undefined = true;
    pysdfgen.addCSourceFile(.{ .file = b.path("python/module.c"), .flags = &.{ "-Wall", "-Werror" } });
    for (python_include) |include| {
        pysdfgen.addIncludePath(.{ .cwd_relative = include });
    }
    if (python_include.len == 0) {
        try pysdfgen.step.addError("python bindings need a list of python include directories, see -Dpython-include option", .{});
    }
    pysdfgen.linkLibC();
    b.installArtifact(pysdfgen);

    const pysdfgen_step = b.step("python", "Library for the Python sdfgen module");
    const pysdfgen_install = b.addInstallFileWithDir(pysdfgen.getEmittedBin(), .lib, pysdfgen_bin);
    pysdfgen_step.dependOn(&pysdfgen_install.step);

    const c_step = b.step("c", "Static library for C bindings");
    c_step.dependOn(&b.addInstallFileWithDir(csdfgen.getEmittedBin(), .lib, "csdfgen").step);
    c_step.dependOn(&csdfgen.step);

    const c_example = b.addExecutable(.{
        .name = "c_example",
        .target = target,
        .optimize = optimize,
    });
    c_example.addCSourceFile(.{ .file = b.path("examples/examples.c") });
    c_example.linkLibrary(csdfgen);
    c_example.linkLibC();

    const c_example_step = b.step("c_example", "Run example program using C bindings");
    const c_example_cmd = b.addRunArtifact(c_example);
    // In case any sDDF configuration files are changed
    c_example_cmd.addDirectoryArg(b.path("sddf"));
    _ = try c_example_cmd.step.addDirectoryWatchInput(b.path("sddf"));
    c_example_step.dependOn(&c_example_cmd.step);

    const c_example_install = b.addInstallFileWithDir(c_example.getEmittedBin(), .bin, "c_example");

    // wasm executable
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });
    const wasm = b.addExecutable(.{
        .name = "gui_sdfgen",
        .root_source_file = b.path("src/gui_sdfgen.zig"),
        .target = wasm_target,
        .optimize = .Debug,
        .strip = false,
    });

    wasm.root_module.addImport("dtb", dtb_module);
    wasm.entry = .disabled;
    wasm.root_module.export_symbol_names = &.{ "fetchInitInfo", "jsonToXml" };

    const wasm_step = b.step("wasm", "build wasm");

    const wasm_install = b.addInstallArtifact(wasm, .{});
    wasm_step.dependOn(&wasm_install.step);

    const tests = b.addTest(.{
        .root_source_file = b.path("src/test.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_options = b.addOptions();
    test_options.addOptionPath("c_example", .{ .cwd_relative = b.getInstallPath(.bin, c_example.name) });
    test_options.addOptionPath("test_dir", b.path("tests"));
    test_options.addOptionPath("sddf", b.path("sddf"));

    tests.root_module.addOptions("config", test_options);

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&c_example_install.step);
    // In case any sDDF configuration files are changed
    _ = try test_step.addDirectoryWatchInput(b.path("sddf"));
}
