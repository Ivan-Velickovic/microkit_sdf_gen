const std = @import("std");
const mod_sdf = @import("sdf.zig");
const mod_devicetree = @import("devicetree.zig");
const Allocator = std.mem.Allocator;

const DeviceTree = mod_devicetree.DeviceTree;

pub const MicrokitBoard = struct {
    allocator: Allocator,
    board_type: Type,
    devicetree: DeviceTree,

    pub const Type = enum {
        // board type defined here has to match board name defined in microkit
        // and also name of its dtb file.
        qemu_arm_virt,
        odroidc4,

        // Get the board enum from its string representation
        pub fn fromStr(str: []const u8) !Type {
            inline for (std.meta.fields(Type)) |field| {
                if (std.mem.eql(u8, str, field.name)) {
                    return @enumFromInt(field.value);
                }
            }
            return error.BoardNotFound;
        }

        // @ericc: Print out enum fields, for debugging only I assume
        // pub fn printFields() void {
        //     comptime var i: usize = 0;
        //     const fields = @typeInfo(@This()).Enum.fields;
        //     inline while (i < fields.len) : (i += 1) {
        //         std.debug.print("{s}\n", .{fields[i].name});
        //     }
        // }
    };

    pub fn create(allocator: Allocator, board_type: Type, dtbs_path: []const u8) !MicrokitBoard {
        const devicetree = try DeviceTree.parseDtb(allocator, dtbs_path, @tagName(board_type));
        return MicrokitBoard{ .allocator = allocator, .board_type = board_type, .devicetree = devicetree };
    }

    pub fn deinit(b: *MicrokitBoard) void {
        b.devicetree.deinit();
    }

    // Get architecture for each board
    pub fn arch(b: *MicrokitBoard) mod_sdf.SystemDescription.Arch {
        return switch (b.board_type) {
            .qemu_arm_virt, .odroidc4 => .aarch64,
        };
    }
};