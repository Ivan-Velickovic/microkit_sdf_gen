const std = @import("std");
const mod_dtb = @import("dtb");
const mod_sdf = @import("sdf.zig");
const Allocator = std.mem.Allocator;
const allocPrint = std.fmt.allocPrint;

const SystemDescription = mod_sdf.SystemDescription;
const Interrupt = SystemDescription.Interrupt;

// TODO: This whole dtb wrapper stuff probably warrants a redesign, right now
// its just a whole lot of questionable code duplication
pub const DeviceTree = struct {
    allocator: Allocator,
    root_node: Node,

    pub const Node = struct {
        internal_node: *mod_dtb.Node,
        
        pub const Prop = union(enum) {
            Compatible: []const []const u8,
            Reg: []const [2]u128,
            Interrupts: []const []const u32,
        };

        pub fn prop(node: *Node, comptime prop_tag: std.meta.Tag(Prop)) ?std.meta.TagPayload(Prop, prop_tag) {
            return switch (prop_tag) {
                .Compatible => return node.internal_node.prop(.Compatible),
                .Reg => return node.internal_node.prop(.Reg),
                .Interrupts => return node.internal_node.prop(.Interrupts),
            };
        }
    };

    pub fn parseDtb(allocator: Allocator, dtbs_path: []const u8, dtb_name: []const u8) !DeviceTree {
        // Check that path to DTB exists
        std.log.info("starting DTB parse", .{});
        std.log.info("opening DTB root dir '{s}'", .{dtbs_path});
        const dtbs_dir = std.fs.cwd().openDir(dtbs_path, .{}) catch |e| {
            switch (e) {
                error.FileNotFound => {
                    std.log.info("Path to DTB directory '{s}' does not exist\n", .{dtbs_path});
                },
                else => {
                    std.log.info("Could not access DTB directory '{s}' due to error: {}\n", .{ dtbs_path, e });
                },
            }
            return e;
        };
        const dtb_file_name = try allocPrint(allocator, "{s}.dtb", .{dtb_name});
        defer allocator.free(dtb_file_name);
        std.log.info("searching for: '{s}'", .{dtb_file_name});
        const dtb_file = dtbs_dir.openFile(dtb_file_name, .{}) catch |e| {
            if (e == error.FileNotFound) {
                std.log.info("could not find DTB file '{s}'", .{dtb_file_name});
            }
            return e;
        };
        defer dtb_file.close();
        const dtb_size = (try dtb_file.stat()).size;
        const dtb_bytes = try dtb_file.reader().readAllAlloc(allocator, dtb_size);
        const dtb = mod_dtb.parse(allocator, dtb_bytes) catch |e| {
            std.log.info("could not parse DTB file '{s}'", .{dtb_file_name});
            return e;
        };
        return DeviceTree{ .allocator = allocator, .root_node = Node{ .internal_node = dtb } };
    }

    // TODO: maybe should move this into the external dtb module instead?
    // Given the name of a dtb node, return the first found descendent node that matches the name.
    pub fn findNode(devicetree: *DeviceTree, name: []const u8) ?Node {
        const res = recursiveFindNode(devicetree.root_node.internal_node, name) orelse return null;
        return Node{ .internal_node = res};
    }

    fn recursiveFindNode(internal_node: *mod_dtb.Node, name: []const u8) ?*mod_dtb.Node {
        if (std.mem.eql(u8, internal_node.name, name)) {
            return internal_node;
        }
        for (internal_node.children) |children| {
            const target = recursiveFindNode(children, name);
            if (target != null) {
                return target;
            }
        }
        return null;
    }

    pub fn deinit(devicetree : *DeviceTree) void {
        devicetree.root_node.internal_node.deinit(devicetree.allocator);
    }

    const ArmGic = struct {
        const IrqType = enum {
            spi,
            ppi,
            extended_spi,
            extended_ppi,
        };

        pub fn irqType(irq_type: usize) !IrqType {
            return switch (irq_type) {
                0x0 => .spi,
                0x1 => .ppi,
                0x2 => .extended_spi,
                0x3 => .extended_ppi,
                else => return error.InvalidArmIrqTypeValue,
            };
        }

        pub fn irqNumber(number: usize, irq_type: IrqType) usize {
            return switch (irq_type) {
                .spi => number + 32,
                .ppi => number, // TODO: check this
                .extended_spi, .extended_ppi => @panic("Unexpected IRQ type"),
            };
        }

        pub fn irqTrigger(trigger: usize) !Interrupt.Trigger {
            return switch (trigger) {
                0x1 => return .edge,
                0x4 => return .level,
                else => return error.InvalidTriggerValue,
            };
        }
    };
};