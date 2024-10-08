const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const dtbzig_dep = b.dependency("dtb.zig", .{});

    const python_include = b.option([]const []const u8, "python-include", "Include directory for Python bindings") orelse &.{};

    const lib = b.addStaticLibrary(.{
        .name = "microkit_sdf_gen",
        .root_source_file = b.path("src/sdf.zig"),
        .target = target,
        .optimize = optimize,
    });

    const sdfgen_step = b.step("sdfgen", "Utility for testing and developing examples of SDF auto-generation");
    const sdfgen = b.addExecutable(.{
        .name = "sdfgen",
        .root_source_file = b.path("src/sdfgen.zig"),
        .target = target,
        .optimize = optimize,
    });

    // We want to be able to import the 'dtb.zig' library as a module.
    const dtb_module = dtbzig_dep.module("dtb");
    sdfgen.root_module.addImport("dtb", dtb_module);

    const sdfgen_cmd = b.addRunArtifact(sdfgen);
    if (b.args) |args| {
        sdfgen_cmd.addArgs(args);
    }

    sdfgen_step.dependOn(&sdfgen_cmd.step);
    const sdfgen_install = b.addInstallArtifact(sdfgen, .{});
    sdfgen_step.dependOn(&sdfgen_install.step);

    b.installArtifact(lib);

    const main_tests = b.addTest(.{
        .root_source_file = b.path("src/test.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_main_tests = b.addRunArtifact(main_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_main_tests.step);

    const modsdf = b.addModule("sdf", .{
        .root_source_file = b.path("src/mod.zig")
    });
    modsdf.addImport("dtb", dtbzig_dep.module("dtb"));

    const csdfgen = b.addStaticLibrary(.{
        .name = "csdfgen",
        .root_source_file = b.path("src/c/c.zig"),
        .target = target,
        .optimize = optimize,
    });
    csdfgen.linkLibC();
    csdfgen.root_module.addImport("sdf", modsdf);

    const pysdfgen_bin = b.option([]const u8, "pysdfgen-emit", "Build pysdfgen library") orelse "pysdfgen.so";
    const pysdfgen = b.addSharedLibrary(.{
        .name = "pysdfgen",
        .target = target,
        .optimize = optimize,
    });
    pysdfgen.linkLibrary(csdfgen);
    pysdfgen.linker_allow_shlib_undefined = true;
    pysdfgen.addCSourceFile(.{
        .file = b.path("python/module.c"),
        .flags = &.{
            "-Wall",
            "-Werror"
        }
    });
    for (python_include) |include| {
        pysdfgen.addIncludePath(.{ .cwd_relative = include });
    }
    if (python_include.len == 0) {
        try pysdfgen.step.addError("python bindings need a list of python include directories, see -Dpython-include option", .{});
    }
    pysdfgen.linkLibC();
    pysdfgen.addIncludePath(b.path("src/c"));
    b.installArtifact(pysdfgen);

    const pysdfgen_step = b.step("python", "Library for the Python sdfgen module");
    const pysdfgen_install = b.addInstallFileWithDir(pysdfgen.getEmittedBin(), .lib, pysdfgen_bin);
    pysdfgen_step.dependOn(&pysdfgen_install.step);

    const c_example_step = b.step("c", "Example of using csdfgen with C");
    const c_example = b.addExecutable(.{
        .name = "c_example",
        .target = target,
        .optimize = optimize,
    });
    c_example.addCSourceFile(.{ .file = b.path("c/example.c") });
    c_example.linkLibrary(csdfgen);
    c_example.addIncludePath(b.path("src/c"));
    c_example.linkLibC();
    const c_example_cmd = b.addRunArtifact(c_example);

    c_example_step.dependOn(&c_example_cmd.step);
    const c_example_install = b.addInstallArtifact(c_example, .{});
    c_example_step.dependOn(&c_example_install.step);

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
}
