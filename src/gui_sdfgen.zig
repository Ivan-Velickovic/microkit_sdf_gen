const std = @import("std");

const mod_sdf = @import("sdf.zig");
const sddf = @import("sddf.zig");
const dtb = @import("dtb");

const Allocator = std.mem.Allocator;
const SystemDescription = mod_sdf.SystemDescription;
const Pd = SystemDescription.ProtectionDomain;
const Mr = SystemDescription.MemoryRegion;
const Vm = SystemDescription.VirtualMachine;
const Map = SystemDescription.Map;
const Irq = SystemDescription.Interrupt;
const Channel = SystemDescription.Channel;
const ProgramImage = Pd.ProgramImage;
const DeviceTree = sddf.DeviceTree;

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

    const vm_copy = try sdf.allocator.create(Vm);
    vm_copy.* = vm_new;
    return vm_copy;
}

fn getMRByName(sdf: *SystemDescription, name: []const u8) !Mr {
    for (sdf.mrs.items) |mr| {
        if (std.mem.eql(u8, name, mr.name)) {
            return mr;
        }
    }
    return error.InvalidMrName;
}

fn parsePDFromJson(sdf: *SystemDescription, node_config: anytype) !*Pd {
    const pd_image = ProgramImage.create(node_config.get("prog_img").?.string);
    var pd_new = Pd.create(sdf, node_config.get("name").?.string, pd_image);
    pd_new.budget = @intCast(node_config.get("budget").?.integer);
    pd_new.priority = @intCast(node_config.get("priority").?.integer);
    pd_new.period = @intCast(node_config.get("period").?.integer);
    pd_new.pp = node_config.get("pp").?.bool;

    const children = node_config.get("children").?.array;
    var i: usize = 0;
    while (i < children.items.len) : (i += 1) {
        const child_config = children.items[i].object;
        const node_type = child_config.get("type").?.string;

        if (std.mem.eql(u8, node_type, "PD")) {
            const child_pd = parsePDFromJson(sdf, child_config) catch {
                return error.FailToParsePD;
            };
            pd_new.addChild(child_pd) catch |err| {
                return err;
            };
        } else if (std.mem.eql(u8, node_type, "VM")) {
            const child_vm = parseVMFromJson(sdf, child_config) catch {
                return error.FailToParseVM;
            };
            pd_new.addVirtualMachine(child_vm) catch |err| {
                return err;
            };
        }
    }

    const map_configs = node_config.get("maps").?.array;
    i = 0;
    while (i < map_configs.items.len) : (i += 1) {
        const map_config = map_configs.items[i].object;
        const map_new = parseMapFromJson(sdf, map_config) catch |err| {
            return err;
        };
        pd_new.addMap(map_new);
    }

    const irq_configs = node_config.get("irqs").?.array;
    i = 0;
    while (i < irq_configs.items.len) : (i += 1) {
        const irq_config = irq_configs.items[i].object;
        const irq_new = parseIrqFromJson(irq_config) catch |err| {
            return err;
        };
        pd_new.addInterrupt(irq_new) catch |err| {
            return err;
        };
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
}

fn parseMRFromJson(sdf: *SystemDescription, mr_config: anytype) !Mr {
    const name = mr_config.get("name").?.string;

    const size: usize = @intCast(mr_config.get("size").?.integer);
    // const phys_addr: usize = @intCast(mr_config.get("phys_addr").?.integer);
    var phys_addr: ?usize = null;
    if (mr_config.get("phys_addr")) |phys_addr_json| {
        switch (phys_addr_json) {
            .integer => {
                phys_addr = @intCast(phys_addr_json.integer);
            },
            .null => {},
            else => @panic("Invalid phys_addr JSON"),
        }
    }
    // const page_size: Mr.PageSize = @intCast(mr_config.get("page_size").?.integer);
    const mr_new = Mr.create(sdf, name, size, phys_addr, .small);

    return mr_new;
}

fn parseIrqFromJson(irq_config: anytype) !Irq {
    const irq_num: usize = @intCast(irq_config.get("irq").?.integer);
    const id: usize = @intCast(irq_config.get("id_").?.integer);
    const trigger_str = irq_config.get("trigger").?.string;
    var trigger : Irq.Trigger = .edge;
    if (std.mem.eql(u8, trigger_str, "level")) {
        trigger = .level;
    } else if (std.mem.eql(u8, trigger_str, "edge")) {
        trigger = .edge;
    } else {
        return error.InvalidTrigger;
    }
    const irq_new = Irq.create(irq_num, trigger, id);
    return irq_new;
}

fn parseMapFromJson(sdf: *SystemDescription, map_config: anytype) !Map {
    const mr = getMRByName(sdf, map_config.get("mr").?.string) catch |err| {
        return err;
    };

    const vaddr: usize = @intCast(map_config.get("vaddr").?.integer);
    const perm_r = map_config.get("perm_r").?.bool;
    const perm_w = map_config.get("perm_w").?.bool;
    const perm_x = map_config.get("perm_x").?.bool;
    const cached = map_config.get("cached").?.bool;
    const setvar_vaddr = map_config.get("setvar_vaddr").?.string;
    const map = Map.create(mr, vaddr, .{ .read = perm_r, .write = perm_w, .execute = perm_x }, cached, setvar_vaddr);
    return map;
}

fn parseSddfSubsystemFromJson(sdf: *SystemDescription, subsystem_config: anytype, blob: *dtb.Node) !void {
    const class = subsystem_config.get("class").?.string;
    const driver_name = subsystem_config.get("driver_name").?.string;
    const mux_tx_name = subsystem_config.get("serial_mux_tx").?.string;
    const mux_rx_name = subsystem_config.get("serial_mux_rx").?.string;

    if (std.mem.eql(u8, class, "serial")) {
        const clients = subsystem_config.get("clients").?.array;
        if (clients.items.len != 2) {
            return;
        }
        const client1_name = clients.items[0].string;
        const client2_name = clients.items[1].string;

        var uart_node: ?*dtb.Node = undefined;
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
        const driver = getPDByName(sdf, driver_name) catch {
            return error.PdCannotBeFound;
        };
        var serial_system = sddf.SerialSystem.init(sdf.allocator, sdf, 0x200000);
        serial_system.setDriver(driver, uart_node.?);

        const mux_tx = getPDByName(sdf, mux_tx_name) catch {
            return error.PdCannotBeFound;
        };
        const mux_rx = getPDByName(sdf, mux_rx_name) catch {
            return error.PdCannotBeFound;
        };

        serial_system.setMultiplexors(mux_rx, mux_tx);

        const client1_pd = getPDByName(sdf, client1_name) catch {
            return error.PdCannotBeFound;
        };
        const client2_pd = getPDByName(sdf, client2_name) catch {
            return error.PdCannotBeFound;
        };
        serial_system.addClient(client1_pd);
        serial_system.addClient(client2_pd);
        serial_system.connect() catch {
            return error.ConnectError;
        };
    }
}

fn parseAndBuild(sdf: *SystemDescription, json: anytype, blob: *dtb.Node) ![]const u8 {
    const pds = json.get("pds").?.array;
    const channels = json.get("channels").?.array;
    const mrs = json.get("mrs").?.array;
    const sddf_subsystems = json.get("sddf_subsystems").?.array;

    var i: usize = 0;
    while (i < mrs.items.len) : (i += 1) {
        const mr_config = mrs.items[i].object;

        const mr_new = parseMRFromJson(sdf, mr_config) catch {
            return "Failed to parse MR";
        };
        sdf.addMemoryRegion(mr_new);
    }

    i = 0;
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

    i = 0;
    while (i < sddf_subsystems.items.len) : (i += 1) {
        const subsystem_config = sddf_subsystems.items[i].object;

        parseSddfSubsystemFromJson(sdf, subsystem_config, blob) catch {
            return "Failed to parse sddf_subsystem";
        };
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

    const xml = parseAndBuild(&sdf, object, blob) catch {
        return printMsg(result_ptr, "Failed to parse the attributes!");
    };

    // const xml = abstractions(allocator, &sdf, blob) catch {
    //     return printMsg(result_ptr, "Failed to create sample system: abstractions");
    // };

    return printMsg(result_ptr, xml);
}

fn getDtJson(allocator: Allocator, blob: *dtb.Node, writer: anytype) !void {
    _ = try writer.write("{");
    const json_string = try std.fmt.allocPrint(allocator, "\"name\":\"{s}\",\"compatibles\":", .{blob.name});
    defer allocator.free(json_string);

    _ = try writer.write(json_string);

    _ = try writer.write("[");
    if (blob.prop(.Compatible)) |compatibles| {
        for (compatibles, 0..) |compatible, i| {
            if (i != 0) {
               _ =  try writer.write(", ");
            }
            const compatible_string = try std.fmt.allocPrint(allocator, "\"{s}\"", .{compatible});
            defer allocator.free(compatible_string);
            _ = try writer.write(compatible_string);
        }
    }
    _ = try writer.write("]");

    if (blob.children.len == 0) {
        if (blob.prop(.Interrupts)) |interrupts| {
            if (interrupts.len == 1 and interrupts[0].len == 3) {
                _ = try writer.write(", \"irq\":{");
                const irq_type = try DeviceTree.armGicIrqType(interrupts[0][0]);
                const irq_number = DeviceTree.armGicIrqNumber(interrupts[0][1], irq_type);

                // const irq_trigger = try DeviceTree.armGicIrqTrigger(interrupts[0][2]);
                // const irq_string = try std.fmt.allocPrint(allocator, "\"irq_number\": {any}, \"irq_trigger\": {any}", .{ irq_number, irq_trigger });
                const irq_string = try std.fmt.allocPrint(allocator, "\"irq_number\": {any}, \"irq_trigger\": {any}", .{ irq_number, interrupts[0][2] });
                defer allocator.free(irq_string);
                _ = try writer.write(irq_string);

                _ = try writer.write("}");
            }
        }
    }

    _ = try writer.write(",\"children\":[");
    for (blob.children, 0..) |child, i| {
        if (i != 0) {
            _ = try writer.write(", ");
        }
        getDtJson(allocator, child, writer) catch |err| {
            return err;
        };
    }
    _ = try writer.write("]}");
}

export fn getDeviceTree(input_ptr: [*]const u8, input_len: usize, result_ptr: [*]u8) usize {
    const input = input_ptr[0..input_len];
    const allocator = std.heap.wasm_allocator;
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, input, .{}) catch {
        return printMsg(result_ptr, "Invalid JSON string!");
    };
    defer parsed.deinit();

    const object = parsed.value.object;
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

    const blob = dtb.parse(allocator, dtb_bytes.items) catch {
        return printMsg(result_ptr, "DTB parsing error");
    };
    defer blob.deinit(allocator);

    var dt_data = std.ArrayList(u8).init(allocator);
    defer dt_data.deinit();

    getDtJson(allocator, blob, dt_data.writer()) catch {
        return printMsg(result_ptr, "Failed to parse DTB children ");
    };


    return printMsg(result_ptr, dt_data.items[0..dt_data.items.len]);
}
