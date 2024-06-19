const std = @import("std");
const mod_sdf = @import("sdf.zig");
const mod_microkitboard = @import("microkitboard.zig");
const mod_devicetree = @import("devicetree.zig");
const Allocator = std.mem.Allocator;
const allocPrint = std.fmt.allocPrint;

const MicrokitBoard = mod_microkitboard.MicrokitBoard;

const DeviceTree = mod_devicetree.DeviceTree;

const SystemDescription = mod_sdf.SystemDescription;
const Mr = SystemDescription.MemoryRegion;
const Map = SystemDescription.Map;
const Pd = SystemDescription.ProtectionDomain;
const ProgramImage = Pd.ProgramImage;
const Interrupt = SystemDescription.Interrupt;
const Channel = SystemDescription.Channel;

///
/// Expected sDDF repository layout:
///     -- drivers/
///         -- network/
///         -- serial/
///         ...
///
/// Essentially there should be a top-level directory
/// for each device class inside 'drivers/'.
///

pub const Sddf = struct {
    drivers_meta: std.ArrayList(Meta.Driver),

    // As part of the initilisation, we want to find all the JSON configuration
    // files, parse them, and built up a data structure for us to then search
    // through whenever we want to create a driver to the system description.
    pub fn probe(allocator: Allocator, sddf_path: []const u8) !Sddf {        
        var sddf = Sddf{
            .drivers_meta = std.ArrayList(Meta.Driver).init(allocator),
        };

        std.log.info("starting sDDF probe", .{});
        std.log.info("opening sDDF root dir '{s}'", .{sddf_path});
        // Check that path to sDDF exists
        var sddf_dir = std.fs.cwd().openDir(sddf_path, .{}) catch |e| {
            switch (e) {
                error.FileNotFound => {
                    std.log.info("Path to sDDF '{s}' does not exist\n", .{sddf_path});
                },
                else => {
                    std.log.info("Could not access sDDF directory '{s}' due to error: {}\n", .{ sddf_path, e });
                },
            }
            return e;
        };
        defer sddf_dir.close();

        // Enumerate over device classes in Meta.DeviceClass, but need to convert this comptime reflection to runtime
        const device_classes = comptime std.meta.fields(Meta.DeviceClass);
        var device_classes_arr: [device_classes.len]Meta.DeviceClass = undefined;
        inline for (device_classes, 0..) |field, i| {
            device_classes_arr[i] = @enumFromInt(field.value);
        }

        for (device_classes_arr) |device_class| {
            // Probe for drivers
            const drivers_name = try allocPrint(allocator, "drivers/{s}", .{@tagName(device_class)});
            defer allocator.free(drivers_name);
            std.log.info("searching through: '{s}'", .{drivers_name});
            var drivers_dir = sddf_dir.openDir(drivers_name, .{ .iterate = true }) catch |e| {
                switch (e) {
                    error.FileNotFound => {
                        std.log.info("could not find drivers directory at 'drivers/{s}', skipping...", .{@tagName(device_class)});
                        continue;
                    },
                    else => return e,
                }
            };
            defer drivers_dir.close();

            var iter = drivers_dir.iterate();
            while (try iter.next()) |entry| {
                if (entry.kind != .directory) {
                    continue;
                }
                
                std.log.info("searching through: 'drivers/{s}/{s}'", .{@tagName(device_class), entry.name});
                var driver_dir = try drivers_dir.openDir(entry.name, .{});
                defer driver_dir.close();

                const driver_meta_file = driver_dir.openFile("meta.json", .{}) catch |e| {
                    switch (e) {
                        error.FileNotFound => {
                            std.log.info("could not find config file at '{s}', skipping...", .{entry.name});
                            continue;
                        },
                        else => return e,
                    }
                };
                defer driver_meta_file.close();
                const driver_meta_size = (try driver_meta_file.stat()).size;
                const driver_meta_bytes = try driver_meta_file.reader().readAllAlloc(allocator, driver_meta_size);
                std.debug.assert(driver_meta_bytes.len == driver_meta_size);
                // TODO: we have no information if the parsing fails. We need to do some error output if
                // it the input is malformed.
                // We are using an ArenaAllocator so calling parseFromSliceLeaky instead of parseFromSlice
                // is recommended. But this also means allocation made here cannot be individually freed.
                // TODO: Conditionally call parseFromSlice instead of parseFromSliceLeaky based on allocator type.
                // and then call defer .deinit() if we are using parseFromSlice.
                // std.log.info("{s}", .{driver_meta_bytes});
                // TODO: Deallocating driver_meta_bytes with defer corrupts the driver_json??? Need to investigate
                const driver_json = try std.json.parseFromSliceLeaky(Meta.Driver.Json, allocator, driver_meta_bytes, .{});
                try sddf.drivers_meta.append(Meta.Driver.fromJson(driver_json, @tagName(device_class)));
            }
        }

        return sddf;
    }

    // Assumes probe() has been called
    fn findDriverMeta(sddf: *const Sddf, compatibles: []const []const u8) ?Meta.Driver {
        for (sddf.drivers_meta.items) |driver| {
            // This is yet another point of weirdness with device trees. It is often
            // the case that there are multiple compatible strings for a device and
            // accompanying driver. So we get the user to provide a list of compatible
            // strings, and we check for a match with any of the compatible strings
            // of a driver.
            for (compatibles) |compatible| {
                for (driver.compatibles) |driver_compatible| {
                    if (std.mem.eql(u8, driver_compatible, compatible)) {
                        // We have found a compatible driver
                        return driver;
                    }
                }
            }
        }
        return null;
    }

    pub fn deinit(sddf: *const Sddf) void {
        sddf.drivers_meta.deinit();
    }
};

// sDDF drivers populated by probe().
pub const Meta = struct {
    pub const DeviceClass = enum {
        // Device classes defined here have to match the directory names in sDDF
        // block,
        // network,
        serial,

        pub fn fromStr(str: []const u8) DeviceClass {
            inline for (std.meta.fields(DeviceClass)) |field| {
                if (std.mem.eql(u8, str, field.name)) {
                    return @enumFromInt(field.value);
                }
            }
            // TODO: don't panic
            @panic("Unexpected device class string given");
        }
    };

    /// There is some extra information we want
    /// to store that is not specified in the JSON meta info.
    /// For example, the device class that the driver belongs to.
    pub const Driver = struct {
        class: DeviceClass,
        compatibles: []const []const u8,

        pub const Json = struct {
            compatibles: [][]const u8,
        };

        pub fn fromJson(json: Json, class: []const u8) Driver {
            return .{
                .class = DeviceClass.fromStr(class),
                .compatibles = json.compatibles,
            };
        }
    };
};

// Usage of this Serial System:
// 1. Create a Serial System via create(), this will use the default sDDF objects and configurations.
// 2. (Optional) set sDDF objects and configurations explicitly, do so via setDevice(), setVirtRx(), setVirtTx().
//    If those have been set then regenerate the system's sdf objects via genSdfObjs().
// 3. (Optional) Set the system's sdf objects directly, via setSdfDriver(), setSdfVirtRx(), setSdfVirtTx()
// 4. Add clients to the system via addSdfClient()
// 5. Add the system to the system description via addToSystemDescription()
pub const SerialSystem = struct {
    allocator: Allocator,
    board: *MicrokitBoard,
    sddf: *Sddf,
    sdf: *SystemDescription,
    region_size: usize,
    page_size: Mr.PageSize,
    driver_meta: Meta.Driver,
    device: DeviceTree.Node,
    virt_rx: Pd,
    virt_tx: Pd,
    driver: Pd,
    device_mr: Mr,
    driver_virt_tx_mrs: SerialSystem.MemoryRegions,
    driver_virt_rx_mrs: SerialSystem.MemoryRegions,
    driver_virt_tx_ch: Channel,
    driver_virt_rx_ch: Channel,
    clients: std.ArrayList(*Pd),
    clients_mrs: std.ArrayList(SerialSystem.MemoryRegions),
    clients_ch: std.ArrayList(Channel),

    const DRV_NAME: []const u8 = "serial_driver";
    const VIRT_TX_NAME: []const u8 = "serial_virt_tx";
    const VIRT_RX_NAME: []const u8 = "serial_virt_rx";
    const DRV_DEV_MR_NAME: []const u8 = "serial_drv_dev";
    const DRV_TX_DATA_NAME: []const u8 = "serial_drv_tx_data";
    const DRV_TX_QUEUE_NAME: []const u8 = "serial_drv_tx_queue";
    const DRV_RX_DATA_NAME: []const u8 = "serial_drv_rx_data";
    const DRV_RX_QUEUE_NAME: []const u8 = "serial_drv_rx_queue";
    const DRV_DEV_SETVAR: []const u8 = "uart_base";
    const DRV_TX_QUEUE_SETVAR: []const u8 = "tx_queue";
    const DRV_TX_DATA_SETVAR: []const u8 = "tx_data";
    const DRV_RX_QUEUE_SETVAR: []const u8 = "rx_queue";
    const DRV_RX_DATA_SETVAR: []const u8 = "rx_data";
    const VIRT_TX_DRV_QUEUE_SETVAR: []const u8 = "tx_queue_drv";
    const VIRT_TX_DRV_DATA_SETVAR: []const u8 = "tx_data_drv";
    const VIRT_RX_DRV_QUEUE_SETVAR: []const u8 = "rx_queue_drv";
    const VIRT_RX_DRV_DATA_SETVAR: []const u8 = "rx_data_drv";
    const DRV_DEV_VADDR: usize = 0x4_000_000;
    const DRV_TX_QUEUE_VADDR: usize = 0x5_000_000;
    const DRV_TX_DATA_VADDR: usize = 0x5_200_000;
    const DRV_RX_QUEUE_VADDR: usize = 0x5_400_000;
    const DRV_RX_DATA_VADDR: usize = 0x5_600_000;
    const VIRT_TX_DRV_QUEUE_VADDR: usize = 0x5_000_000;
    const VIRT_TX_DRV_DATA_VADDR: usize = 0x5_200_000;
    const VIRT_RX_DRV_QUEUE_VADDR: usize = 0x5_000_000;
    const VIRT_RX_DRV_DATA_VADDR: usize = 0x5_200_000;

    pub const MemoryRegions = struct {
        // If we want to be able to dynamically remove clients from the system,
        // we need to keep track of the memory regions and channels that are
        // associated with each client. In that scenario we will need an identifier
        // in this struct to identify which client these memory regions belong to.
        data: Mr,
        queue: Mr,
    };

    pub fn create(allocator: Allocator, board: *MicrokitBoard, sddf: *Sddf, sdf: *SystemDescription) SerialSystem {
        var system = SerialSystem{
            .allocator = allocator,
            .board = board,
            .sddf = sddf,
            .sdf = sdf,
            .region_size = undefined,
            .page_size = undefined,
            .driver_meta = undefined,
            .device = undefined,
            .virt_rx = undefined,
            .virt_tx = undefined,
            .driver = undefined,
            .device_mr = undefined,
            .driver_virt_tx_mrs = undefined,
            .driver_virt_rx_mrs = undefined,
            .driver_virt_tx_ch = undefined,
            .driver_virt_rx_ch = undefined,
            .clients = std.ArrayList(*Pd).init(allocator),
            .clients_mrs = std.ArrayList(SerialSystem.MemoryRegions).init(allocator),
            .clients_ch = std.ArrayList(Channel).init(allocator),
        };
        
        setDefault(&system);
        return system;
    }
    
    pub fn deinit(system: *SerialSystem) void {
        system.clients_mrs.deinit();
        system.clients_ch.deinit();
        system.clients.deinit();
    }

    // TODO: Expose configurable fields e.g. region_size and page_size, to user.
    // Use board defaults to initialise the serial system.
    pub fn setDefault(system: *SerialSystem) void {
        // Set serial protocol memory sizes
        system.region_size = 0x200_000;
        system.page_size = SystemDescription.MemoryRegion.PageSize.optimal(system.board.arch(), system.region_size);

        // Init default device
        system.device = switch (system.board.board_type) {
            MicrokitBoard.Type.qemu_arm_virt => system.board.devicetree.findNode("pl011@9000000").?,
            MicrokitBoard.Type.odroidc4 => system.board.devicetree.findNode("serial@3000").?,
        };
        system.driver_meta = system.sddf.findDriverMeta(system.device.prop(.Compatible).?).?;

        // Create memory region for device
        // TODO: I'm assuming there is only 1 mem region for serial devices
        const dev_regions: [2]u128 = system.device.prop(.Reg).?[0];
        // TODO: we're converting u128 to usize here... fix later
        const dev_region_base: usize = @intCast(dev_regions[0]);
        const dev_region_size: usize = @intCast(dev_regions[1]);
        system.device_mr = Mr.create(system.sdf, DRV_DEV_MR_NAME, dev_region_base, dev_region_size, system.page_size);

        // Create serial driver
        const driver_image = ProgramImage.create(allocPrint(system.allocator, "{s}.elf", .{DRV_NAME}) catch @panic("Could not allocate memory for allocPrint"));
        defer system.allocator.free(driver_image.path);
        system.driver = Pd.create(system.sdf, DRV_NAME, driver_image);
        system.driver.priority = 100;
        // TODO: I'm assuming only 1 interrupt exists for serial devices
        const interrupts = system.device.prop(.Interrupts).?[0];
        const interrupt_num: usize = interrupts[1];
        const trigger: Interrupt.Trigger = switch (interrupts[2]) {
            0x01 => Interrupt.Trigger.edge,
            0x04 => Interrupt.Trigger.level,
            else => @panic("Unknown interrupt trigger"),
        };
        const interrupt = Interrupt.create(interrupt_num, trigger, null);
        system.driver.addInterrupt(interrupt) catch @panic("Could not add interrupt to driver");
        system.driver.addMap(Map.create(system.device_mr, DRV_DEV_VADDR, .{ .read = true, .write = true }, false, DRV_DEV_SETVAR));

        // Create virtualiser TX
        const virt_tx_image = ProgramImage.create(allocPrint(system.allocator, "{s}.elf", .{VIRT_TX_NAME}) catch @panic("Could not allocate memory for allocPrint"));
        defer system.allocator.free(virt_tx_image.path);
        system.virt_tx = Pd.create(system.sdf, VIRT_TX_NAME, virt_tx_image);
        system.virt_tx.priority = 99;
        
        // Create virtualiser RX
        const virt_rx_image = ProgramImage.create(allocPrint(system.allocator, "{s}.elf", .{VIRT_RX_NAME}) catch @panic("Could not allocate memory for allocPrint"));
        defer system.allocator.free(virt_rx_image.path);
        system.virt_rx = Pd.create(system.sdf, VIRT_RX_NAME, virt_rx_image);
        system.virt_rx.priority = 98;

        // Create memory regions for driver virtualiser TX
        const tx_queue_mr = Mr.create(system.sdf, DRV_TX_QUEUE_NAME, system.region_size, null, system.page_size);
        const tx_data_mr = Mr.create(system.sdf, DRV_TX_DATA_NAME, system.region_size, null, system.page_size);
        system.driver_virt_tx_mrs = .{
            .data = tx_data_mr,
            .queue = tx_queue_mr,
        };
        system.driver.addMap(Map.create(system.driver_virt_tx_mrs.queue, DRV_TX_QUEUE_VADDR, .{ .read = true, .write = true }, false, DRV_TX_QUEUE_SETVAR));
        system.driver.addMap(Map.create(system.driver_virt_tx_mrs.data, DRV_TX_DATA_VADDR, .{ .read = true, .write = true }, false, DRV_TX_DATA_SETVAR));
        system.virt_tx.addMap(Map.create(system.driver_virt_tx_mrs.queue, VIRT_TX_DRV_QUEUE_VADDR, .{ .read = true, .write = true }, false, VIRT_TX_DRV_QUEUE_SETVAR));
        system.virt_tx.addMap(Map.create(system.driver_virt_tx_mrs.data, VIRT_TX_DRV_DATA_VADDR, .{ .read = true, .write = true }, false, VIRT_TX_DRV_DATA_SETVAR));

        // Create memory regions for driver virtualiser RX
        const rx_queue_mr = Mr.create(system.sdf, DRV_RX_QUEUE_NAME, system.region_size, null, system.page_size);
        const rx_data_mr = Mr.create(system.sdf, DRV_RX_DATA_NAME, system.region_size, null, system.page_size);
        system.driver_virt_rx_mrs = .{
            .data = rx_data_mr,
            .queue = rx_queue_mr,
        };
        system.driver.addMap(Map.create(system.driver_virt_rx_mrs.queue, DRV_RX_QUEUE_VADDR, .{ .read = true, .write = true }, false, DRV_RX_QUEUE_SETVAR));
        system.driver.addMap(Map.create(system.driver_virt_rx_mrs.data, DRV_RX_DATA_VADDR, .{ .read = true, .write = true }, false, DRV_RX_DATA_SETVAR));
        system.virt_rx.addMap(Map.create(system.driver_virt_rx_mrs.queue, VIRT_RX_DRV_QUEUE_VADDR, .{ .read = true, .write = true }, false, VIRT_RX_DRV_QUEUE_SETVAR));
        system.virt_rx.addMap(Map.create(system.driver_virt_rx_mrs.data, VIRT_RX_DRV_DATA_VADDR, .{ .read = true, .write = true }, false, VIRT_RX_DRV_DATA_SETVAR));
        
        // Create channels for driver virtualiser TX & RX
        system.driver_virt_tx_ch = Channel.create(&system.driver, &system.virt_tx);
        system.driver_virt_rx_ch = Channel.create(&system.driver, &system.virt_rx);
    }

    // TODO: Rethink how to implement the set functions below...
    // Set sDDF device to node name in device tree
    pub fn setDevice(system: *SerialSystem, name: []const u8) error.SddfMetaNotFound!void {
        errdefer system.device = undefined;
        errdefer system.driver_meta = undefined;
        const device = system.board.devicetree.findNode(name) orelse return error.SddfMetaNotFound;
        system.device = device;
        const compatibles = system.device.prop(.Compatible) orelse return error.SddfMetaNotFound;
        const driver_meta = system.sddf.findDriverMeta(compatibles) orelse return error.SddfMetaNotFound;
        system.driver_meta = driver_meta;
    }

    pub fn setVirtRx(system: *SystemDescription, name: []const u8) error.SddfMetaNotFound!void {
        _ = .{ system, name };
    }

    pub fn setVirtTx(system: *SystemDescription, name: []const u8) error.SddfMetaNotFound!void {
        _ = .{ system, name };
    }

    pub const ConnectionInfo = struct {
        type: ConnectionType,
        cli_name: []const u8,
        cli_tx_vaddr: ?[]const u8,
        cli_rx_vaddr: ?[]const u8,
        cli_tx_setvar: ?usize,
        cli_rx_setvar: ?usize,
        cli_tx_ch: ?u32,
        cli_rx_ch: ?u32,

        pub const ConnectionType = enum {
            Tx,
            Rx,
            All,
        };
    };

    // Add client to the system. Will create MRs and Channels for the client needed by the serial system,
    // and add that as mappings to the client's PD.
    pub fn addClient(system: *SerialSystem, client: *Pd, con_info: SerialSystem.ConnectionInfo) error.InvalidConnectionInfo!void {
        switch (con_info.type) {
            .Tx => {
                try addClientTx(system, client, con_info);
            },
            .Rx => {
                try addClientRx(system, client, con_info);
            },
            .All => {
                try addClientTx(system, client, con_info);
                try addClientRx(system, client, con_info);
            },
        }
        system.clients.append(client) catch @panic("Could not append client to SerialSystem.clients");
    }

    fn addClientTx(system: *SerialSystem, client: *Pd, con_info: SerialSystem.ConnectionInfo) error.InvalidConnectionInfo!void {
        if (con_info.cli_tx_vaddr == null or con_info.cli_tx_ch == null) {
            return error.InvalidConnectionInfo;
        }
        const tx_queue_name = allocPrint(system.allocator, "{s}_serial_tx_queue", .{con_info.cli_name}) catch @panic("Could not allocate memory for allocPrint");
        defer system.allocator.free(tx_queue_name);
        const tx_data_name = allocPrint(system.allocator, "{s}_serial_tx_data", .{con_info.cli_name}) catch @panic("Could not allocate memory for allocPrint");
        defer system.allocator.free(tx_data_name);
        const tx_queue_mr = Mr.create(system.sdf, tx_queue_name, system.region_size, null, system.page_size);
        const tx_data_mr = Mr.create(system.sdf, tx_data_name, system.region_size, null, system.page_size);
        system.clients_mrs.append(.{
            .data = tx_data_mr,
            .queue = tx_queue_mr,
        }) catch @panic("Could not append memory regions to SerialSystem.clients_mrs");
        client.addMap(Map.create(tx_queue_mr, con_info.cli_tx_vaddr, .{ .read = true, .write = true }, false, con_info.cli_tx_setvar));
        client.addMap(Map.create(tx_data_mr, con_info.cli_tx_vaddr, .{ .read = true, .write = true }, false, con_info.cli_tx_setvar));
        const channel = Channel.create(system.virt_tx, client);
        system.clients_ch.append(channel) catch @panic("Could not append channel to SerialSystem.clients_ch");
    }

    fn addClientRx(system: *SerialSystem, client: *Pd, con_info: SerialSystem.ConnectionInfo) error.InvalidConnectionInfo!void {
        if (con_info.cli_rx_vaddr == null or con_info.cli_rx_ch == null) {
            return error.InvalidConnectionInfo;
        }
        const rx_queue_name = allocPrint(system.allocator, "{s}_serial_rx_queue", .{con_info.cli_name}) catch @panic("Could not allocate memory for allocPrint");
        defer system.allocator.free(rx_queue_name);
        const rx_data_name = allocPrint(system.allocator, "{s}_serial_rx_data", .{con_info.cli_name}) catch @panic("Could not allocate memory for allocPrint");
        defer system.allocator.free(rx_data_name);
        const rx_queue_mr = Mr.create(system.sdf, rx_queue_name, system.region_size, null, system.page_size);
        const rx_data_mr = Mr.create(system.sdf, rx_data_name, system.region_size, null, system.page_size);
        system.clients_mrs.append(.{
            .data = rx_data_mr,
            .queue = rx_queue_mr,
        }) catch @panic("Could not append memory regions to SerialSystem.clients_mrs");
        client.addMap(Map.create(rx_queue_mr, con_info.cli_rx_vaddr, .{ .read = true, .write = true }, false, con_info.cli_rx_setvar));
        client.addMap(Map.create(rx_data_mr, con_info.cli_rx_vaddr, .{ .read = true, .write = true }, false, con_info.cli_rx_setvar));
        const channel = Channel.create(client, system.virt_rx);
        system.clients_ch.append(channel) catch @panic("Could not append channel to SerialSystem.clients_ch");
    }

    pub fn addToSystemDescription(system: *SerialSystem) !void {
        system.sdf.addMemoryRegion(system.device_mr);
        system.sdf.addMemoryRegion(system.driver_virt_tx_mrs.queue);
        system.sdf.addMemoryRegion(system.driver_virt_tx_mrs.data);
        system.sdf.addMemoryRegion(system.driver_virt_rx_mrs.queue);
        system.sdf.addMemoryRegion(system.driver_virt_rx_mrs.data);

        for (system.clients_mrs.items) |client_mrs| {
            system.sdf.addMemoryRegion(client_mrs.queue);
            system.sdf.addMemoryRegion(client_mrs.data);
        }

        system.sdf.addProtectionDomain(&system.driver);
        system.sdf.addProtectionDomain(&system.virt_rx);
        system.sdf.addProtectionDomain(&system.virt_tx);

        for (system.clients.items) |client| {
            system.sdf.addProtectionDomain(client);
        }

        system.sdf.addChannel(system.driver_virt_tx_ch);
        system.sdf.addChannel(system.driver_virt_rx_ch);

        for (system.clients_ch.items) |client_ch| {
            system.sdf.addChannel(client_ch);
        }
    }
};