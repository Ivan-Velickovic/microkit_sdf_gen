const std = @import("std");
const builtin = @import("builtin");
const mod_sdf = @import("sdf.zig");
const mod_vmm = @import("vmm.zig");
const mod_microkitboard = @import("microkitboard.zig");
const mod_sddf = @import("sddf.zig");
const mod_devicetree = @import("devicetree.zig");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;

const MicrokitBoard = mod_microkitboard.MicrokitBoard;
const DeviceTree = mod_devicetree.DeviceTree;
const Sddf = mod_sddf.Sddf;

const SystemDescription = mod_sdf.SystemDescription;
const Pd = SystemDescription.ProtectionDomain;
const Vm = SystemDescription.VirtualMachine;
const ProgramImage = Pd.ProgramImage;
const Mr = SystemDescription.MemoryRegion;
const Map = SystemDescription.Map;
const Irq = SystemDescription.Interrupt;
const Channel = SystemDescription.Channel;

const VirtualMachineSystem = mod_vmm.VirtualMachineSystem;

// var xml_out_path: []const u8 = "example.system";
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

    // Probe sDDF for configuration files
    const sddf = try Sddf.probe(allocator, sddf_path);
    defer sddf.deinit(allocator);  

    // Probe dtb directory for the board we want
    const microkitboard = try MicrokitBoard.create(allocator, MicrokitBoard.MicrokitBoardType.qemu_arm_virt, dtbs_path);
    defer microkitboard.deinit(allocator);

    // The list of compatible drivers will determine what IRQs
    // and memory regions are allocated for the driver. Each device 
    // will have separate memory regions and interrupts needed.
    // My only worry here is that a driver does not necessarily *need* all the memory
    // that a device tree will specify. I think the same can be said of interrupts.
    // For now, and for simplicity, let's leave this as a problem to solve later. Right
    // now we will keep the device tree as the source of truth.  


}
