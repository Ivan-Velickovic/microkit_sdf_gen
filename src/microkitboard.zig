const std = @import("std");
const mod_sdf = @import("sdf.zig");
const mod_devicetree = @import("devicetree.zig");
const Allocator = std.mem.Allocator;

const DeviceTree = mod_devicetree.DeviceTree;

pub const MicrokitBoard = struct {
    board_type: MicrokitBoardType,
    devicetree: DeviceTree,

    pub const MicrokitBoardType = enum {
        qemu_arm_virt,
        odroidc4,

        // Get the board enum from its string representation
        pub fn fromStr(str: []const u8) !MicrokitBoardType {
            inline for (std.meta.fields(MicrokitBoardType)) |field| {
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

    pub fn create(board_type: MicrokitBoardType, devicetree: DeviceTree) MicrokitBoard {
        return MicrokitBoard{ .board_type = board_type, .devicetree = devicetree };
    }

    // Get architecture for each board
    pub fn arch(b: MicrokitBoard) mod_sdf.SystemDescription.Arch {
        return switch (b.board_type) {
            .qemu_arm_virt, .odroidc4 => .aarch64,
        };
    }
};