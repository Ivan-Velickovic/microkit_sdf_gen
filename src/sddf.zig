const std = @import("std");
const mod_sdf = @import("sdf.zig");
const mod_microkitboard = @import("microkitboard.zig");
const mod_devicetree = @import("devicetree.zig");
const Allocator = std.mem.Allocator;
const allocPrint = std.fmt.allocPrint;

const MicrokitBoard = mod_microkitboard.MicrokitBoard;
const MicrokitBoardType = MicrokitBoard.MicrokitBoardType;

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
///     -- network/
///     -- serial/
///     -- drivers/
///         -- network/
///         -- serial/
///
/// Essentially there should be a top-level directory for a
/// device class and aa directory for each device class inside
/// 'drivers/'.
///

pub const Sddf = struct {
    drivers_config: std.ArrayList(Config.Driver),
    components_config: std.ArrayList(Config.Component),

    // As part of the initilisation, we want to find all the JSON configuration
    // files, parse them, and built up a data structure for us to then search
    // through whenever we want to create a driver to the system description.
    pub fn probe(allocator: Allocator, sddf_path: []const u8) !Sddf {
        const sddf = Sddf{
            .drivers_config = std.ArrayList(Config.Driver).init(allocator),
            .components_config = std.ArrayList(Config.Component).init(allocator),
        };

        std.log.info("starting sDDF probe", .{});
        std.log.info("opening sDDF root dir '{s}'", .{sddf_path});
        const sddf_dir = try std.fs.cwd().openDir(sddf_path, .{});
        defer sddf_dir.close();

        const device_classes = comptime std.meta.fields(Config.DeviceClass);
        inline for (device_classes) |device_class| {
            // Probe for drivers
            std.log.info("searching through: 'drivers/{s}'", .{device_class.name});
            const drivers_dir = sddf_dir.openDir("drivers/" ++ device_class.name, .{ .iterate = true }) catch |e| {
                switch (e) {
                    error.FileNotFound => {
                        std.log.info("could not find drivers directory at 'drivers/{s}', skipping...", .{device_class.name});
                        continue;
                    },
                    else => return e,
                }
            };
            defer drivers_dir.close();

            const iter = drivers_dir.iterate();
            while (try iter.next()) |entry| {
                if (entry.kind != .directory) {
                    continue;
                }
                
                std.log.info("searching through: 'drivers/{s}/{s}'", .{device_class.name, entry.name});
                const driver_dir = try drivers_dir.openDir(entry.name, .{});
                defer driver_dir.close();

                const driver_config_file = driver_dir.openFile("config.json", .{}) catch |e| {
                    switch (e) {
                        error.FileNotFound => {
                            std.log.info("could not find config file at '{s}', skipping...", .{entry.name});
                            continue;
                        },
                        else => return e,
                    }
                };
                defer driver_config_file.close();
                const driver_config_size = (try driver_config_file.stat()).size;
                const driver_config_bytes = try driver_config_file.reader().readAllAlloc(allocator, driver_config_size);
                // TODO; free config? we'd have to dupe the json data when populating our data structures
                std.debug.assert(driver_config_bytes.len == driver_config_size);
                const driver_json = try std.json.parseFromSliceLeaky(Config.Driver.Json, allocator, driver_config_bytes, .{});
                // TODO: we have no information if the parsing fails. We need to do some error output if
                // it the input is malformed.
                // TODO: should probably free the memory at some point
                // We are using an ArenaAllocator so calling parseFromSliceLeaky instead of parseFromSlice
                // is recommended.
                try sddf.drivers_config.append(Config.Driver.fromJson(driver_json, device_class.name));
            }

            // Probe for components
            std.log.info("searching through: {s}", .{device_class.name});
            const components_dir = try sddf_dir.openDir(device_class.name, .{});
            defer components_dir.close();

            const component_config_file = components_dir.openFile("config.json", .{}) catch |e| {
                switch (e) {
                    error.FileNotFound => {
                        std.log.info("could not find config file at '{s}', skipping...", .{device_class.name});
                        continue;
                    },
                    else => return e,
                }
            };
            defer component_config_file.close();
            const component_config_size = (try component_config_file.stat()).size;
            const component_config_bytes = try component_config_file.reader().readAllAlloc(allocator, component_config_size);
            std.debug.assert(component_config_bytes.len == component_config_size);
            const component_json = try std.json.parseFromSliceLeaky(Config.Component.Json, allocator, component_config_bytes, .{});
            try sddf.components_config.append(Config.Component.fromJson(component_json, device_class.name));
        }

        return sddf;
    }

    // Assumes probe() has been called
    fn findDriverConfig(sddf: *Sddf, compatibles: []const []const u8) ?*Config.Driver {
        for (sddf.drivers_config.items) |driver| {
            // This is yet another point of weirdness with device trees. It is often
            // the case that there are multiple compatible strings for a device and
            // accompying driver. So we get the user to provide a list of compatible
            // strings, and we check for a match with any of the compatible strings
            // of a driver.
            for (compatibles) |compatible| {
                for (driver.compatible) |driver_compatible| {
                    if (std.mem.eql(u8, driver_compatible, compatible)) {
                        // We have found a compatible driver
                        return driver;
                    }
                }
            }
        }
        return null;
    }

    // Assumes probe() has been called
    fn findComponentConfig(sddf: *Sddf, name: []const u8) ?*Config.Component {
        for (sddf.components_config.items) |component| {
            if (std.mem.eql(u8, component.name, name)) {
                return component;
            }
        }
        return null;
    }

    pub fn deinit(sddf: *Sddf, allocator: Allocator) void {
        allocator.free(sddf.drivers_config);
        allocator.free(sddf.components_config);
    }
};

// TODO: potentially TOO generic, may need to split into serial_drivers, network_drivers, etc.
// instead of combining all into one.
// sDDF drivers/components populated by probe().
pub const Config = struct {
    const Map = struct {
        // Name of the memory mapping
        name: []const u8,
        // Permissions to the memory mapping
        perms: []const u8,
        // TODO: do we need cached or can we decide based on the type?
        cached: bool,
        setvar_vaddr: ?[]const u8,
        page_size: usize,
        size: usize,
    };

    /// The actual IRQ number that gets registered with seL4
    /// is something we can determine from the device tree.
    const Irq = struct {
        name: []const u8,
        id: usize,
    };

    const Channel = struct {
        name: []const u8,
        id: usize,
    };

    pub const DeviceClass = enum {
        // Block,
        // Network,
        Serial,

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

    /// In the case of drivers there is some extra information we want
    /// to store that is not specified in the JSON configuration.
    /// For example, the device class that the driver belongs to.
    pub const Driver = struct {
        class: DeviceClass.Class,
        name: []const u8,
        compatibles: []const []const u8,
        maps: []const Config.Map,
        irqs: []const Config.Irq,
        channels: []const Config.Channel,

        pub const Json = struct {
            name: []const u8,
            compatibles: []const []const u8,
            maps: []const Config.Map,
            irqs: []const Config.Irq,
            channels: []const Config.Channel,
        };

        pub fn fromJson(json: Json, class: []const u8) Driver {
            return .{
                .class = DeviceClass.fromStr(class),
                .name = json.name,
                .compatibles = json.compatibles,
                .maps = json.maps,
                .irqs = json.irqs,
                .channels = json.channels,
            };
        }
    };

    pub const Component = struct {
        class: DeviceClass,
        name: []const u8,
        maps: []const Config.Map,
        channels: []const Config.Channel,

        pub const Json = struct {
            name: []const u8,
            maps: []const Config.Map,
            channels: []const Config.Channel,
        };

        pub fn fromJson(json: Json, class: []const u8) Component {
            return .{
                .class = DeviceClass.fromStr(class),
                .name = json.name,
                .maps = json.maps,
                .channels = json.channels,
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
    virt_rx_config: Config.Component,
    virt_tx_config: Config.Component,
    device: DeviceTree.Node,
    device_config: Config.Driver,
    virt_rx: *Pd,
    virt_tx: *Pd,
    driver: *Pd,
    region_size: usize,
    page_size: Mr.PageSize,
    clients: std.ArrayList(*Pd),

    pub fn create(allocator: Allocator, board: *MicrokitBoard, sddf: *Sddf) SerialSystem {
        const system = SerialSystem{
            .allocator = allocator,
            .board = board,
            .sddf = sddf,
            .virt_rx_config = undefined,
            .virt_tx_config = undefined,
            .driver_config = undefined,
            .device = undefined,
            .virt_rx = undefined,
            .virt_tx = undefined,
            .driver = undefined,
            .region_size = undefined,
            .page_size = undefined,
            .clients = std.ArrayList(*Pd).init(allocator),
        };
        
        setDefault(&system);
        genSdfObjs(&system);
        return system;
    }
    
    pub fn deinit(system: *SerialSystem) void {
        system.allocator.free(system.clients);
    }

    // TODO: Investigate whether its worth chucking all these default strings into its own JSON file.
    // TODO: Call setDevice() and setVirtRx() and setVirtTx() instead of reimplementing the logic here.
    // TODO: Allow each mapping info e.g. region_size and page_size, to be configurable by user.
    // Use board defaults to initialise the serial system.
    pub fn setDefault(system: *SerialSystem) void {
        // Init default device
        system.device = switch (system.board.board_type) {
            MicrokitBoardType.qemu_arm_virt => system.board.devicetree.findNode("pl011@9000000"),
            MicrokitBoardType.odroidc4 => system.board.devicetree.findNode("serial@3000"),
            else => @panic("Board not supported")
        };
        system.driver_config = system.sddf.findDriverConfig(system.device.prop(.Compatible)) orelse @panic("Could not find default driver config for device");

        // Init default virt RX
        const virt_rx_name = "serial_virt_rx";
        system.virt_rx_config = system.sddf.findComponentConfig(virt_rx_name) orelse @panic("Could not find default virt RX config");

        // Init default virt TX
        const virt_tx_name = "serial_virt_tx";
        system.virt_tx_config = system.sddf.findComponentConfig(virt_tx_name) orelse @panic("Could not find default virt TX config");

        system.region_size = 0x200_000;
        system.page_size = SystemDescription.MemoryRegion.PageSize.optimal(system.board.arch(), system.region_size);
    }

    pub fn genSdfObjs(system: *SerialSystem) void {
        _ = system;
    }

    // Set sDDF device to node name in device tree
    pub fn setDevice(system: *SerialSystem, name: []const u8) error.SddfConfigNotFound!void {
        errdefer system.device = undefined;
        errdefer system.driver_config = undefined;
        system.device = system.board.devicetree.findNode(name);
        system.driver_config = system.sddf.findDriverConfig(system.device.prop(.Compatible));
        if (system.driver_config == null) {
            return error.SddfConfigNotFound;
        }
    }

    pub fn setVirtRx(system: *SystemDescription, name: []const u8) error.SddfConfigNotFound!void {
        errdefer system.virt_rx_config = undefined;
        system.virt_rx_config = system.sddf.findComponentConfig(name);
        if (system.virt_rx_config == null) {
            return error.SddfConfigNotFound;
        }
    }

    pub fn setVirtTx(system: *SystemDescription, name: []const u8) error.SddfConfigNotFound!void {
        errdefer system.virt_tx_config = undefined;
        system.virt_tx_config = system.sddf.findComponentConfig(name);
        if (system.virt_tx_config == null) {
            return error.SddfConfigNotFound;
        }
    }

    pub fn setSdfDriver(system: *SerialSystem, driver: *Pd) void {
        system.driver = driver;
    }

    pub fn setSdfVirtRx(system: *SerialSystem, virt_rx: *Pd) void {
        system.virt_rx = virt_rx;
    }

    pub fn setSdfVirtTx(system: *SerialSystem, virt_tx: *Pd) void {
        system.virt_tx = virt_tx;
    }

    pub fn addSdfClient(system: *SerialSystem, client: *Pd) void {
        system.clients.append(client) catch @panic("Could not add client to SerialSystem");
    }

    pub fn addToSystemDescription(system: *SerialSystem, sdf: SystemDescription) !void {
        _ = .{system, sdf};
    }
};