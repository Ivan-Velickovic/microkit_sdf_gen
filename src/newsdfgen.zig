const std = @import("std");
const builtin = @import("builtin");
const mod_sdf = @import("sdf.zig");
const mod_vmm = @import("vmm.zig");
const sddf = @import("sddf.zig");
const mod_microkitboard = @import("microkitboard.zig");
const dtb = @import("dtb");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;

const SystemDescription = mod_sdf.SystemDescription;
const Pd = SystemDescription.ProtectionDomain;
const Vm = SystemDescription.VirtualMachine;
const ProgramImage = Pd.ProgramImage;
const Mr = SystemDescription.MemoryRegion;
const Map = SystemDescription.Map;
const Irq = SystemDescription.Interrupt;
const Channel = SystemDescription.Channel;

const VirtualMachineSystem = mod_vmm.VirtualMachineSystem;

var xml_out_path: []const u8 = "example.system";
var sddf_path: []const u8 = "sddf";
var dtbs_path: []const u8 = "dtbs";

pub fn main() !void {
    // An arena allocator makes much more sense for our purposes, all we're doing is doing a bunch
    // of allocations in a linear fashion and then just tearing everything down. This has better
    // performance than something like the General Purpose Allocator.
    // TODO: have a build argument that swaps the allocator.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const allocator = arena.allocator();
    defer arena.deinit();

    // const args = try std.process.argsAlloc(allocator);
    // defer std.process.argsFree(allocator, args);
    // try parseArgs(args, allocator);

    // Check that path to sDDF exists
    std.fs.cwd().access(sddf_path, .{}) catch |err| {
        switch (err) {
            error.FileNotFound => {
                std.debug.print("Path to sDDF '{s}' does not exist\n", .{sddf_path});
                std.process.exit(1);
            },
            else => {
                std.debug.print("Could not access sDDF directory '{s}' due to error: {}\n", .{ sddf_path, err });
                std.process.exit(1);
            },
        }
    };

    // Check that path to DTB exists
    const board_dtb_path = try std.fmt.allocPrint(allocator, "{s}/{s}.dtb", .{ dtbs_path, @tagName(board) });
    defer allocator.free(board_dtb_path);
    std.fs.cwd().access(board_dtb_path, .{}) catch |err| {
        switch (err) {
            error.FileNotFound => {
                std.debug.print("Path to board DTB '{s}' does not exist\n", .{board_dtb_path});
                std.process.exit(1);
            },
            else => {
                std.debug.print("Could not access DTB directory '{s}' due to error: {}\n", .{ board_dtb_path, err });
                std.process.exit(1);
            },
        }
    };

    // Read the DTB contents
    const dtb_file = try std.fs.cwd().openFile(board_dtb_path, .{});
    const dtb_size = (try dtb_file.stat()).size;
    const blob_bytes = try dtb_file.reader().readAllAlloc(allocator, dtb_size);
    // Parse the DTB
    var blob = try dtb.parse(allocator, blob_bytes);
    // TODO: the allocator should already be known by the DTB...
    defer blob.deinit(allocator);

    // Before doing any kind of XML generation we should probe sDDF for
    // configuration files etc
    try sddf.probe(allocator, sddf_path);

    const compatible_drivers = try sddf.compatibleDrivers(allocator);
    defer allocator.free(compatible_drivers);

    std.debug.print("sDDF drivers found:\n", .{});
    for (compatible_drivers) |driver| {
        std.debug.print("   - {s}\n", .{driver});
    }

    // Now that we have a list of compatible drivers, we need to find what actual
    // devices are available that are compatible. This will determine what IRQs
    // and memory regions are allocated for the driver. Each device will have separate
    // memory regions and interrupts needed.
    // My only worry here is that a driver does not necessarily *need* all the memory
    // that a device tree will specify. I think the same can be said of interrupts.
    // For now, and for simplicity, let's leave this as a problem to solve later. Right
    // now we will keep the device tree as the source of truth.

    var sdf = try SystemDescription.create(allocator, board.arch());
    try example.generate(allocator, &sdf, blob);
}
