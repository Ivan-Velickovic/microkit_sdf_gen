const std = @import("std");
const dtb = @import("dtb");
const mod_sdf = @import("sdf.zig");
const Allocator = std.mem.Allocator;

const SystemDescription = mod_sdf.SystemDescription;
const Interrupt = SystemDescription.Interrupt;

pub const DeviceTree = struct {
    /// Functionality relating the the ARM Generic Interrupt Controller.
    const ArmGicIrqType = enum {
        spi,
        ppi,
        extended_spi,
        extended_ppi,
    };

    pub fn armGicIrqType(irq_type: usize) !ArmGicIrqType {
        return switch (irq_type) {
            0x0 => .spi,
            0x1 => .ppi,
            0x2 => .extended_spi,
            0x3 => .extended_ppi,
            else => return error.InvalidArmIrqTypeValue,
        };
    }

    pub fn armGicIrqNumber(number: usize, irq_type: ArmGicIrqType) usize {
        return switch (irq_type) {
            .spi => number + 32,
            .ppi => number, // TODO: check this
            .extended_spi, .extended_ppi => @panic("Unexpected IRQ type"),
        };
    }

    pub fn armGicIrqTrigger(trigger: usize) !Interrupt.Trigger {
        return switch (trigger) {
            0x1 => return .edge,
            0x4 => return .level,
            else => return error.InvalidTriggerValue,
        };
    }

    // TODO: probably should move this into the external dtb module instead...
    // Given the name of a dtb node, return the first found descendent node that matches the name.
    pub fn findDtbNode(root: *dtb.Node, name: []const u8) ?*dtb.Node {
        if (std.mem.eql(u8, root.name, name)) {
            return root;
        }
        for (root.children) |children| {
            const target = findDtbNode(children, name);
            if (target != null) {
                return target;
            }
        }
        return null;
    }
};

pub fn parseDtb(allocator: Allocator, dtbs_path: []const u8, dtb_name: []const u8) !dtb.Node {
    const dtbs_dir = try std.fs.cwd().access(dtbs_path, .{});
    defer dtbs_dir.close();
    
    const dtb_file = dtbs_dir.openFile(dtb_name, .{}) catch |e| {
        if (e == error.FileNotFound) {
            std.log.info("could not find dtb file '{s}'", .{dtb_name});
        }
        return e;
    };
    defer dtb_file.close();
    const dtb_size = (try dtb_file.stat()).size;
    const dtb_bytes = try dtb_file.reader().readAllAlloc(allocator, dtb_size);
    return try dtb.parse(dtb_bytes);
}