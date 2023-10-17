const std = @import("std");
const builtin = @import("builtin");
const sdf = @import("sdf.zig");
const sddf = @import("sddf.zig");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;

const SystemDescription = sdf.SystemDescription;
const Pd = SystemDescription.ProtectionDomain;
const Vm = SystemDescription.VirtualMachine;
const ProgramImage = Pd.ProgramImage;
const Mr = SystemDescription.MemoryRegion;
const Map = SystemDescription.Map;
const Irq = SystemDescription.Interrupt;
const Channel = SystemDescription.Channel;

const MicrokitBoard = enum {
    qemu_arm_virt,
    odroidc4,
};

fn strToBoard(str: []const u8) !MicrokitBoard {
    if (std.mem.eql(u8, "qemu_arm_virt", str)) {
        return .qemu_arm_virt;
    } else if (std.mem.eql(u8, "odroidc4", str)) {
        return .odroidc4;
    } else {
        return error.BoardNotFound;
    }
}

// In the future, this functionality regarding the UART
// can just be replaced by looking at the device tree for
// the particular board.
const Uart = struct {
    fn paddr(board: MicrokitBoard) usize {
        return switch (board) {
            .qemu_arm_virt => 0x9000000,
            .odroidc4 => 0xff803000,
        };
    }

    fn size(board: MicrokitBoard) usize {
        return switch (board) {
            .qemu_arm_virt, .odroidc4 => 0x1000,
        };
    }

    fn irq(board: MicrokitBoard) usize {
        return switch (board) {
            .qemu_arm_virt => 33,
            .odroidc4 => 225,
        };
    }

    fn trigger(board: MicrokitBoard) Irq.Trigger {
        return switch (board) {
            .qemu_arm_virt => .level,
            .odroidc4 => .edge,
        };
    }
};

fn guestRamVaddr(board: MicrokitBoard) usize {
    return switch (board) {
        .qemu_arm_virt => 0x40000000,
        .odroidc4 => 0x20000000,
    };
}

const SDDF_BUF_SIZE: usize = 1024 * 1024 * 2;
const GUEST_RAM_SIZE: usize = 1024 * 1024 * 128;

// fn serialConnect(system: *SystemDescription, mux: *ProtectionDomain, client: *ProtectionDomain) !void {
//     // Here we create regions to connect a multiplexor with a client
//     const rx_free = Mr.create(&system, "rx_free_" ++ client.name, SDDF_BUF_SIZE, null, .large);
//     const rx_used = Mr.create(&system, "rx_used_" ++ client.name, SDDF_BUF_SIZE, null, .large);
//     const tx_free = Mr.create(&system, "tx_free_" ++ client.name, SDDF_BUF_SIZE, null, .large);
//     const tx_used = Mr.create(&system, "tx_free_" ++ client.name, SDDF_BUF_SIZE, null, .large);
//     const rx_data = Mr.create(&system, "rx_data_" ++ client.name, SDDF_BUF_SIZE, null, .large);
//     const tx_data = Mr.create(&system, "tx_data_" ++ client.name, SDDF_BUF_SIZE, null, .large);
// }

fn parseDriver(allocator: Allocator) !std.json.Parsed(sddf.Driver) {
    const path = "examples/driver.json";
    const driver_description = try std.fs.cwd().openFile(path, .{});
    defer driver_description.close();

    const bytes = try driver_description.reader().readAllAlloc(allocator, 2048);

    const driver = try std.json.parseFromSlice(sddf.Driver, allocator, bytes, .{});

    std.debug.print("{}\n", .{ std.json.fmt(driver.value, .{ .whitespace = .indent_2 }) });

    return driver;
}

pub fn main() !void {
    // An arena allocator makes much more sense for our purposes, all we're doing is doing a bunch
    // of allocations in a linear fashion and then just tearing everything down. This has better
    // performance than something like the General Purpose Allocator.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const allocator = arena.allocator();
    defer arena.deinit();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    // TODO: do this properly...
    const target = try strToBoard(args[2]);
    const xml_path = args[4];

    var system = try SystemDescription.create(allocator, .aarch64);

    // 1. Create UART driver and map in UART device
    const uart_driver_image = ProgramImage.create("uart_driver.elf");
    var uart_driver = Pd.create(allocator, "uart_driver", uart_driver_image);
    uart_driver.priority = 100;
    try system.addProtectionDomain(&uart_driver);

    const uart_mr = Mr.create(&system, "uart", Uart.size(target), Uart.paddr(target), .small);
    try system.addMemoryRegion(uart_mr);
    try uart_driver.addMap(Map.create(uart_mr, 0x5_000_000, .{ .read = true, .write = true }, false, "uart_base"));

    const uart_irq = Irq.create(Uart.irq(target), Uart.trigger(target), null);
    try uart_driver.addInterrupt(uart_irq);

    const driver = try parseDriver(allocator);
    var uart_driver_test = try sddf.createDriver(&system, driver.value, Uart.paddr(target));
    try system.addProtectionDomain(&uart_driver_test);

    // 2. Create MUX RX
    const serial_mux_rx_image = ProgramImage.create("serial_mux_rx.elf");
    var serial_mux_rx = Pd.create(allocator, "serial_mux_rx", serial_mux_rx_image);
    serial_mux_rx.priority = 98;
    try system.addProtectionDomain(&serial_mux_rx);

    // 3. Create MUX TX
    const serial_mux_tx_image = ProgramImage.create("serial_mux_tx.elf");
    var serial_mux_tx = Pd.create(allocator, "serial_mux_tx", serial_mux_tx_image);
    serial_mux_tx.priority = 99;
    try system.addProtectionDomain(&serial_mux_tx);

    // 4. Create native serial device
    const serial_tester_image = ProgramImage.create("serial_tester.elf");
    var serial_tester = Pd.create(allocator, "serial_tester", serial_tester_image);
    serial_tester.priority = 97;
    try system.addProtectionDomain(&serial_tester);

    // 5. Connect UART driver and MUX RX
    const rx_free = Mr.create(&system, "rx_free_driver", SDDF_BUF_SIZE, null, .large);
    const rx_used = Mr.create(&system, "rx_used_driver", SDDF_BUF_SIZE, null, .large);
    const rx_data = Mr.create(&system, "rx_data_driver", SDDF_BUF_SIZE, null, .large);
    try system.addMemoryRegion(rx_free);
    try system.addMemoryRegion(rx_used);
    try system.addMemoryRegion(rx_data);

    const rx_free_map = Map.create(rx_free, 0x20_000_000, .{ .read = true, .write = true }, true, "rx_free");
    const rx_used_map = Map.create(rx_used, 0x20_200_000, .{ .read = true, .write = true }, true, "rx_used");
    const rx_data_map = Map.create(rx_data, 0x20_400_000, .{ .read = true, .write = true }, true, null);

    try serial_mux_rx.addMap(rx_free_map);
    try serial_mux_rx.addMap(rx_used_map);
    try serial_mux_rx.addMap(rx_data_map);
    try uart_driver.addMap(rx_free_map);
    try uart_driver.addMap(rx_used_map);
    try uart_driver.addMap(rx_data_map);

    const uart_mux_rx_channel = Channel.create(&uart_driver, &serial_mux_rx);
    try system.addChannel(uart_mux_rx_channel);

    // 6. Connect UART driver and MUX TX
    const tx_free = Mr.create(&system, "tx_free_driver", SDDF_BUF_SIZE, null, .large);
    const tx_used = Mr.create(&system, "tx_used_driver", SDDF_BUF_SIZE, null, .large);
    const tx_data = Mr.create(&system, "tx_data_driver", SDDF_BUF_SIZE, null, .large);
    try system.addMemoryRegion(tx_free);
    try system.addMemoryRegion(tx_used);
    try system.addMemoryRegion(tx_data);

    const tx_free_map = Map.create(tx_free, 0x40_000_000, .{ .read = true, .write = true }, true, "tx_free");
    const tx_used_map = Map.create(tx_used, 0x40_200_000, .{ .read = true, .write = true }, true, "tx_used");
    const tx_data_map = Map.create(tx_data, 0x40_400_000, .{ .read = true, .write = true }, true, null);

    try serial_mux_tx.addMap(tx_free_map);
    try serial_mux_tx.addMap(tx_used_map);
    try serial_mux_tx.addMap(tx_data_map);
    try uart_driver.addMap(tx_free_map);
    try uart_driver.addMap(tx_used_map);
    try uart_driver.addMap(tx_data_map);

    const uart_mux_tx_ch = Channel.create(&uart_driver, &serial_mux_tx);
    try system.addChannel(uart_mux_tx_ch);

    // 7. Connect MUX RX and serial tester
    const rx_free_serial_tester = Mr.create(&system, "rx_free_serial_tester", SDDF_BUF_SIZE, null, .large);
    const rx_used_serial_tester = Mr.create(&system, "rx_used_serial_tester", SDDF_BUF_SIZE, null, .large);
    const rx_data_serial_tester = Mr.create(&system, "rx_data_serial_tester", SDDF_BUF_SIZE, null, .large);
    try system.addMemoryRegion(rx_free_serial_tester);
    try system.addMemoryRegion(rx_used_serial_tester);
    try system.addMemoryRegion(rx_data_serial_tester);

    const rx_free_serial_tester_map = Map.create(rx_free_serial_tester, 0x60_000_000, .{ .read = true, .write = true }, true, null);
    const rx_used_serial_tester_map = Map.create(rx_used_serial_tester, 0x60_200_000, .{ .read = true, .write = true }, true, null);
    const rx_data_serial_tester_map = Map.create(rx_data_serial_tester, 0x60_400_000, .{ .read = true, .write = true }, true, null);
    try serial_mux_rx.addMap(rx_free_serial_tester_map);
    try serial_mux_rx.addMap(rx_used_serial_tester_map);
    try serial_mux_rx.addMap(rx_data_serial_tester_map);
    try serial_tester.addMap(rx_free_serial_tester_map);
    try serial_tester.addMap(rx_used_serial_tester_map);
    try serial_tester.addMap(rx_data_serial_tester_map);

    const serial_mux_rx_tester_ch = Channel.create(&serial_mux_rx, &serial_tester);
    try system.addChannel(serial_mux_rx_tester_ch);

    // 8. Connect MUX TX and serial tester
    const tx_free_serial_tester = Mr.create(&system, "tx_free_serial_tester", SDDF_BUF_SIZE, null, .large);
    const tx_used_serial_tester = Mr.create(&system, "tx_used_serial_tester", SDDF_BUF_SIZE, null, .large);
    const tx_data_serial_tester = Mr.create(&system, "tx_data_serial_tester", SDDF_BUF_SIZE, null, .large);
    try system.addMemoryRegion(tx_free_serial_tester);
    try system.addMemoryRegion(tx_used_serial_tester);
    try system.addMemoryRegion(tx_data_serial_tester);

    const tx_free_serial_tester_map = Map.create(tx_free_serial_tester, 0x80_000_000, .{ .read = true, .write = true }, true, null);
    const tx_used_serial_tester_map = Map.create(tx_used_serial_tester, 0x80_200_000, .{ .read = true, .write = true }, true, null);
    const tx_data_serial_tester_map = Map.create(tx_data_serial_tester, 0x80_400_000, .{ .read = true, .write = true }, true, null);
    try serial_mux_tx.addMap(tx_free_serial_tester_map);
    try serial_mux_tx.addMap(tx_used_serial_tester_map);
    try serial_mux_tx.addMap(tx_data_serial_tester_map);
    try serial_tester.addMap(tx_free_serial_tester_map);
    try serial_tester.addMap(tx_used_serial_tester_map);
    try serial_tester.addMap(tx_data_serial_tester_map);

    // 9. Create the virtual machine and virtual-machine-monitor
    const vmm_image = ProgramImage.create("vmm.elf");
    var vmm = Pd.create(allocator, "vmm", vmm_image);

    var guest = Vm.create(allocator, "linux");
    const guest_ram = Mr.create(&system, "guest_ram", GUEST_RAM_SIZE, null, .large);
    try system.addMemoryRegion(guest_ram);

    const guest_ram_map = Map.create(guest_ram, guestRamVaddr(target), .{ .read = true, .execute = true }, true, null);
    try guest.addMap(guest_ram_map);

    // Then we add the virtual machine to the VMM
    const guest_ram_map_vmm = Map.create(guest_ram, guestRamVaddr(target), .{ .read = true }, true, null);
    try vmm.addMap(guest_ram_map_vmm);
    try vmm.addVirtualMachine(&guest);

    try system.addProtectionDomain(&vmm);

    // Get the XML representation
    const xml = try system.toXml();

    // Lastly, write out the XML output to the user-provided path
    var xml_file = try std.fs.cwd().createFile(xml_path, .{});
    defer xml_file.close();
    _ = try xml_file.write(xml);

    if (builtin.mode == .Debug) {
        std.debug.print("{s}", .{ xml });
    }
}
