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
        var sddf = Sddf{
            .drivers_config = std.ArrayList(Config.Driver).init(allocator),
            .components_config = std.ArrayList(Config.Component).init(allocator),
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

        // Enumerate over device classes in Config.DeviceClass, but need to convert this comptime reflection to runtime
        const device_classes = comptime std.meta.fields(Config.DeviceClass);
        var device_classes_arr: [device_classes.len]Config.DeviceClass = undefined;
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
                std.debug.assert(driver_config_bytes.len == driver_config_size);
                // TODO: we have no information if the parsing fails. We need to do some error output if
                // it the input is malformed.
                // We are using an ArenaAllocator so calling parseFromSliceLeaky instead of parseFromSlice
                // is recommended. But this also means allocation made here cannot be individually freed.
                // TODO: Conditionally call parseFromSlice instead of parseFromSliceLeaky based on allocator type.
                // and then call defer .deinit() if we are using parseFromSlice.
                // std.log.info("{s}", .{driver_config_bytes});
                // TODO: Deallocating driver_config_bytes corrupts the driver_json??? Need to investigate
                const driver_json = try std.json.parseFromSliceLeaky(Config.Driver.Json, allocator, driver_config_bytes, .{});
                try sddf.drivers_config.append(Config.Driver.fromJson(driver_json, @tagName(device_class)));
            }

            // Probe for components
            const components_name = try allocPrint(allocator, "{s}/components", .{@tagName(device_class)});
            std.log.info("searching through: '{s}'", .{components_name});
            var components_dir = try sddf_dir.openDir(components_name, .{});
            defer components_dir.close();

            const components_config_file = components_dir.openFile("config.json", .{}) catch |e| {
                switch (e) {
                    error.FileNotFound => {
                        std.log.info("could not find config file at '{s}', skipping...", .{@tagName(device_class)});
                        continue;
                    },
                    else => return e,
                }
            };
            defer components_config_file.close();
            const components_config_size = (try components_config_file.stat()).size;
            const components_config_bytes = try components_config_file.reader().readAllAlloc(allocator, components_config_size);
            std.debug.assert(components_config_bytes.len == components_config_size);
            const components_json = try std.json.parseFromSliceLeaky([]Config.Component.Json, allocator, components_config_bytes, .{});
            for (components_json) |component_json| {
                try sddf.components_config.append(Config.Component.fromJson(component_json, @tagName(device_class)));
            }
        }

        return sddf;
    }

    // Assumes probe() has been called
    fn findDriverConfig(sddf: *Sddf, compatibles: []const []const u8) ?Config.Driver {
        for (sddf.drivers_config.items) |driver| {
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

    // Assumes probe() has been called
    fn findComponentConfig(sddf: *Sddf, name: []const u8) ?Config.Component {
        for (sddf.components_config.items) |component| {
            if (std.mem.eql(u8, component.name, name)) {
                return component;
            }
        }
        return null;
    }

    pub fn deinit(sddf: *Sddf) void {
        sddf.drivers_config.deinit();
        sddf.components_config.deinit();
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

    /// In the case of drivers there is some extra information we want
    /// to store that is not specified in the JSON configuration.
    /// For example, the device class that the driver belongs to.
    pub const Driver = struct {
        class: DeviceClass,
        name: []const u8,
        compatibles: []const []const u8,
        maps: []const Config.Map,
        irqs: []const Config.Irq,
        channels: []const Config.Channel,

        pub const Json = struct {
            name: []const u8,
            compatibles: [][]const u8,
            maps: []const Config.Map,
            irqs: []const Config.Irq,
            channels: []const Config.Channel,
        };

        pub fn fromJson(json: Json, class: []const u8) Driver {
            // Here we assume the first element in the JSON array
            // is our driver config... fe
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
    board: MicrokitBoard,
    sddf: Sddf,
    virt_rx_config: Config.Component,
    virt_tx_config: Config.Component,
    driver_config: Config.Driver,
    device: DeviceTree.Node,
    virt_rx: *Pd,
    virt_tx: *Pd,
    driver: *Pd,
    region_size: usize,
    page_size: Mr.PageSize,
    clients: std.ArrayList(*Pd),

    pub fn create(allocator: Allocator, board: MicrokitBoard, sddf: Sddf) SerialSystem {
        var system = SerialSystem{
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
        system.clients.deinit();
    }

    // TODO: Investigate whether its worth chucking all these default strings into its own JSON file.
    // TODO: Call setDevice() and setVirtRx() and setVirtTx() instead of reimplementing the logic here.
    // TODO: Allow each mapping info e.g. region_size and page_size, to be configurable by user.
    // Use board defaults to initialise the serial system.
    pub fn setDefault(system: *SerialSystem) void {
        // Init default device
        system.device = switch (system.board.board_type) {
            MicrokitBoard.Type.qemu_arm_virt => system.board.devicetree.findNode("pl011@9000000").?,
            MicrokitBoard.Type.odroidc4 => system.board.devicetree.findNode("serial@3000").?,
        };
        system.driver_config = system.sddf.findDriverConfig(system.device.prop(.Compatible).?).?;

        // Init default virt RX
        const virt_rx_name = "serial_virt_rx";
        system.virt_rx_config = system.sddf.findComponentConfig(virt_rx_name).?;

        // Init default virt TX
        const virt_tx_name = "serial_virt_tx";
        system.virt_tx_config = system.sddf.findComponentConfig(virt_tx_name).?;

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
        const device = system.board.devicetree.findNode(name) orelse return error.SddfConfigNotFound;
        system.device = device;
        const compatibles = system.device.prop(.Compatible) orelse return error.SddfConfigNotFound;
        const driver_config = system.sddf.findDriverConfig(compatibles) orelse return error.SddfConfigNotFound;
        system.driver_config = driver_config;
    }

    pub fn setVirtRx(system: *SystemDescription, name: []const u8) error.SddfConfigNotFound!void {
        errdefer system.virt_rx_config = undefined;
        system.virt_rx_config = system.sddf.findComponentConfig(name) orelse return error.SddfConfigNotFound;
    }

    pub fn setVirtTx(system: *SystemDescription, name: []const u8) error.SddfConfigNotFound!void {
        errdefer system.virt_tx_config = undefined;
        system.virt_tx_config = system.sddf.findComponentConfig(name) orelse return error.SddfConfigNotFound;
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

    pub fn addToSystemDescription(system: *SerialSystem, sdf: *SystemDescription) !void {
        _ = .{system, sdf};
    }
};