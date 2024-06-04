const dtb = @import("dtb");
const mod_sdf = @import("sdf.zig");

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
    // Given compatible strings, return the first found dtb node that matches any compatible string.
    pub fn findDtbNodeFromCompat(node: *dtb.Node, compatibles: []const []const u8) ?*dtb.Node {
        const curr_compatible = node.prop(.Compatible);
        if (curr_compatible != null) {
            for (compatibles) |compatible| {
                if (curr_compatible == compatible) {
                    return node;
                }
            }
            return null;
        }

        for (node.children()) |child| {
            const descendent = findDtbNodeFromCompat(child, compatibles);
            if (descendent != null) {
                return descendent;
            }
        }

        return null;
    }
};