const std = @import("std");
const mod_sdf = @import("sdf.zig");
const dtb = @import("dtb");

pub const MicrokitBoard = struct {
    boardType: MicrokitBoardType,
    blob: *dtb.Node,

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

    // TODO: Don't pass in a dtb.Node here, let the system find it itself.
    pub fn create(boardType: MicrokitBoardType, blob: *dtb.Node) MicrokitBoard {
        return MicrokitBoard{ .boardType = boardType, .blob = blob };
    }

    // Get architecture for each board
    pub fn arch(b: MicrokitBoard) mod_sdf.SystemDescription.Arch {
        return switch (b.boardType) {
            .qemu_arm_virt, .odroidc4 => .aarch64,
        };
    }
    
    // Get the driver name prefix for each board
    pub fn driverPrefix(b: MicrokitBoard) []const u8 {
        return switch (b.boardType) {
            .qemu_arm_virt => "arm",
            .odroidc4 => "meson",
        };
    }
};