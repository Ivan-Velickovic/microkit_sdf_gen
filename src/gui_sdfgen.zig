const std = @import("std");

const mod_sdf = @import("sdf.zig");
const sddf = @import("sddf.zig");
const dtb = @import("dtb");

const Allocator = std.mem.Allocator;
const SystemDescription = mod_sdf.SystemDescription;
const Pd = SystemDescription.ProtectionDomain;
const Mr = SystemDescription.MemoryRegion;
const Vm = SystemDescription.VirtualMachine;
const Channel = SystemDescription.Channel;
const ProgramImage = Pd.ProgramImage;

var dtbs_path: []const u8 = "dtbs";
var board: MicrokitBoard = undefined;

const MicrokitBoard = enum {
    qemu_arm_virt,
    odroidc4,

    pub fn fromStr(str: []const u8) !MicrokitBoard {
        inline for (std.meta.fields(MicrokitBoard)) |field| {
            if (std.mem.eql(u8, str, field.name)) {
                return @enumFromInt(field.value);
            }
        }

        return error.BoardNotFound;
    }

    pub fn arch(b: MicrokitBoard) SystemDescription.Arch {
        return switch (b) {
            .qemu_arm_virt, .odroidc4 => .aarch64,
        };
    }

    // pub fn printFields() void {
    //     comptime var i: usize = 0;
    //     const fields = @typeInfo(@This()).Enum.fields;
    //     inline while (i < fields.len) : (i += 1) {
    //         std.debug.print("{s}\n", .{fields[i].name});
    //     }
    // }

    /// Get the Device Tree node for the UART we want to use for
    /// each board
    pub fn uartNode(b: MicrokitBoard) []const u8 {
        return switch (b) {
            .qemu_arm_virt => "pl011@9000000",
            .odroidc4 => "serial@3000",
        };
    }
};

fn abstractions(allocator: Allocator, sdf: *SystemDescription, blob: *dtb.Node) ![]const u8 {
    const image = ProgramImage.create("uart_driver.elf");
    var driver = Pd.create(sdf, "uart_driver", image);
    sdf.addProtectionDomain(&driver);

    var uart_node: ?*dtb.Node = undefined;
    // TODO: We would probably want some helper functionality that just takes
    // the full node name such as "/soc/bus@ff8000000/serial@3000" and would
    // find the DTB node info that we need. For now, this fine.
    switch (board) {
        .odroidc4 => {
            const soc_node = blob.child("soc").?;
            const bus_node = soc_node.child("bus@ff800000").?;
            uart_node = bus_node.child("serial@3000");
        },
        .qemu_arm_virt => {
            uart_node = blob.child(board.uartNode());
        },
    }

    if (uart_node == null) {
        // std.log.err("Could not find UART node '{s}'", .{board.uartNode()});
        // std.process.exit(1);
        // return 9999;
        return "Could not find UART node";
    }

    var serial_system = sddf.SerialSystem.init(allocator, sdf, 0x200000);
    serial_system.setDriver(&driver, uart_node.?);

    // const clients = [_][]const u8{ "client1", "client2", "client3" };

    const mux_rx_image = ProgramImage.create("mux_rx.elf");
    var mux_rx = Pd.create(sdf, "mux_rx", mux_rx_image);
    sdf.addProtectionDomain(&mux_rx);

    const mux_tx_image = ProgramImage.create("mux_tx.elf");
    var mux_tx = Pd.create(sdf, "mux_tx", mux_tx_image);
    sdf.addProtectionDomain(&mux_tx);

    serial_system.setMultiplexors(&mux_rx, &mux_tx);

    const client1_image = ProgramImage.create("client1.elf");
    var client1_pd = Pd.create(sdf, "client1", client1_image);
    serial_system.addClient(&client1_pd);

    sdf.addProtectionDomain(&client1_pd);

    const client2_image = ProgramImage.create("client2.elf");
    var client2_pd = Pd.create(sdf, "client2", client2_image);
    serial_system.addClient(&client2_pd);
    sdf.addProtectionDomain(&client2_pd);

    serial_system.connect() catch {
        return "connect error";
    };

    const xml = sdf.toXml();
    return xml;
}

fn parseVMFromJson(sdf: *SystemDescription, node_config: anytype) !*Vm {
    var vm_new = Vm.create(sdf, node_config.get("name").?.string);
    vm_new.budget = @intCast(node_config.get("budget").?.integer);
    vm_new.priority = @intCast(node_config.get("priority").?.integer);
    vm_new.period = @intCast(node_config.get("period").?.integer);
    // vm_new.pp = node_config.get("pp").?.bool;

    const vm_copy = try sdf.allocator.create(Vm);
    vm_copy.* = vm_new;
    return vm_copy;
}

fn parsePDFromJson(sdf: *SystemDescription, node_config: anytype) !*Pd {
    const pd_image = ProgramImage.create(node_config.get("prog_img").?.string);
    var pd_new = Pd.create(sdf, node_config.get("name").?.string, pd_image);
    pd_new.budget = @intCast(node_config.get("budget").?.integer);
    pd_new.priority = @intCast(node_config.get("priority").?.integer);
    pd_new.period = @intCast(node_config.get("period").?.integer);
    // pd_new.pp = node_config.get("pp").?.bool;

    const children = node_config.get("children").?.array;
    var i: usize = 0;
    while (i < children.items.len) : (i += 1) {
        const child_config = children.items[i].object;
        const node_type = child_config.get("type").?.string;

        if (std.mem.eql(u8, node_type, "PD")) {
            const child_pd = parsePDFromJson(sdf, child_config) catch {
                return error.FailToParse;
            };
            pd_new.addChild(child_pd) catch |err| {
                return err;
            };
        } else if (std.mem.eql(u8, node_type, "VM")) {
            const child_vm = parseVMFromJson(sdf, child_config) catch {
                return error.FailToParse;
            };
            pd_new.addVirtualMachine(child_vm) catch |err| {
                return err;
            };
        }
    }

    const pd_copy = try sdf.allocator.create(Pd);
    // defer pd_copy.destroy();

    pd_copy.* = pd_new;
    return pd_copy;
}

fn getPDByName(sdf: *SystemDescription, name: []const u8) !*Pd {
    for (sdf.pds.items) |pd| {
        if (std.mem.eql(u8, name, pd.name)) {
            return pd;
        }
    }
    return error.InvalidPdName;
}

fn parseChannelFromJson(sdf: *SystemDescription, channel_config: anytype) !Channel {
    const pd1_name = channel_config.get("pd1").?.string;
    const pd2_name = channel_config.get("pd2").?.string;
    const pd1 = getPDByName(sdf, pd1_name) catch {
        return error.PdCannotBeFound;
    };
    const pd2 = getPDByName(sdf, pd2_name) catch {
        return error.PdCannotBeFound;
    };

    var channel_new = Channel.create(pd1, pd2);
    channel_new.pd1_end_id = @intCast(channel_config.get("pd1_end_id").?.integer);
    channel_new.pd2_end_id = @intCast(channel_config.get("pd2_end_id").?.integer);

    return channel_new;
    // const channel_copy = try sdf.allocator.create(Channel);

    // channel_copy.* = channel_new;
    // return channel_copy;
}

fn parseMRFromJson(sdf: *SystemDescription, mr_config: anytype) !Mr {
    const name = mr_config.get("name").?.string;
    const size: usize = @intCast(mr_config.get("size").?.integer);
    const phys_addr: usize = @intCast(mr_config.get("phys_addr").?.integer);
    // const page_size: Mr.PageSize = @intCast(mr_config.get("page_size").?.integer);
    const mr_new = Mr.create(sdf, name, size, phys_addr, .small);

    return mr_new;
    // const mr_copy = try sdf.allocator.create(Mr);

    // mr_copy.* = mr_new;
    // return mr_copy;
}

fn parseAndBuild(sdf: *SystemDescription, json: anytype) ![]const u8 {
    const pds = json.get("pds").?.array;
    const channels = json.get("channels").?.array;
    const mrs = json.get("mrs").?.array;

    var i: usize = 0;
    while (i < pds.items.len) : (i += 1) {
        const pd_config = pds.items[i].object;

        const pd_new = parsePDFromJson(sdf, pd_config) catch {
            return "Failed to parse PD";
        };
        sdf.addProtectionDomain(pd_new);
    }

    i = 0;
    while (i < channels.items.len) : (i += 1) {
        const channel_config = channels.items[i].object;

        const channel_new = parseChannelFromJson(sdf, channel_config) catch {
            return "Failed to parse Channel";
        };
        sdf.addChannel(channel_new);
    }

    while (i < mrs.items.len) : (i += 1) {
        const mr_config = mrs.items[i].object;

        const mr_new = parseMRFromJson(sdf, mr_config) catch {
            return "Failed to parse MR";
        };
        sdf.addMemoryRegion(mr_new);
    }

    const xml = sdf.toXml();
    return xml;
}

fn printMsg(result_ptr: [*]u8, msg: []const u8) usize {
    std.mem.copyForwards(u8, result_ptr[0..msg.len], msg);
    return msg.len;
}

// Compile: zig build wasm
// Copy to GUI repo: cp zig-out/bin/gui_sdfgen.wasm ../lionsos_vis/public

export fn jsonToXml(input_ptr: [*]const u8, input_len: usize, result_ptr: [*]u8) usize {
    const input = input_ptr[0..input_len];

    const allocator = std.heap.wasm_allocator;

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, input, .{}) catch {
        return 1;
    };
    defer parsed.deinit();

    const object = parsed.value.object;

    // Check that path to DTB exists
    const board_str = object.get("board").?.string;
    board = MicrokitBoard.fromStr(board_str) catch {
        return printMsg(result_ptr, "Failed to read board");
    };

    const blob_bytes = object.get("dtb").?.array;

    // We take the 64-bit integer array of the DTB from JS and convert it to an
    // array of bytes.
    var dtb_bytes = std.ArrayList(u8).initCapacity(allocator, blob_bytes.items.len + 1) catch {
        return printMsg(result_ptr, "Failed to allocate memory for DTB bytes");
    };
    defer dtb_bytes.deinit();
    var i: usize = 0;
    while (i < blob_bytes.items.len) : (i += 1) {
        dtb_bytes.append(@intCast(blob_bytes.items[i].integer)) catch {
            return printMsg(result_ptr, "Failed to read DTB bytes");
        };
    }

    // Add final terminal byte
    dtb_bytes.append(0) catch {
        return 202;
    };

    var blob = dtb.parse(allocator, dtb_bytes.items) catch {
        return printMsg(result_ptr, "DTB parsing error");
    };
    // TODO: the allocator should already be known by the DTB...
    defer blob.deinit(allocator);

    var sdf = SystemDescription.create(allocator, board.arch()) catch {
        return printMsg(result_ptr, "Faild to create a system description");
    };
    // defer sdf.destroy();

    const drivers = object.get("drivers").?.array;
    const classes = object.get("deviceClasses").?.array;
    sddf.wasmProbe(allocator, drivers, classes) catch {
        return printMsg(result_ptr, "Faild to probe sDDF");
    };
    const compatible_drivers = sddf.compatibleDrivers(allocator) catch {
        return printMsg(result_ptr, "Faild to find compatible drivers");
    };
    defer allocator.free(compatible_drivers);

    // const pds = object.get("pds").?.array;
    const xml = parseAndBuild(&sdf, object) catch {
        return printMsg(result_ptr, "Failed to parse the attributes!");
    };

    // const xml = abstractions(allocator, &sdf, blob) catch {
    //     return printMsg(result_ptr, "Failed to create sample system: abstractions");
    // };

    return printMsg(result_ptr, xml);
}
