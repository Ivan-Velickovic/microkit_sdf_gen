const std = @import("std");
const mod_sdf = @import("sdf.zig");
const mod_microkitboard = @import("microkitboard.zig");
const mod_dtb = @import("dtb");
const Allocator = std.mem.Allocator;
const allocPrint = std.fmt.allocPrint;

const SystemDescription = mod_sdf.SystemDescription;
const Mr = SystemDescription.MemoryRegion;
const Map = SystemDescription.Map;
const Pd = SystemDescription.ProtectionDomain;
const ProgramImage = Pd.ProgramImage;
const Interrupt = SystemDescription.Interrupt;
const Channel = SystemDescription.Channel;

const MicrokitBoard = mod_microkitboard.MicrokitBoard;
const MicrokitBoardType = MicrokitBoard.MicrokitBoardType;

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

// pub fn probe(allocator: Allocator, sddf_dir_path: []const u8) !void {
// }

// Systems: Block, Network, Serial
// -- Components
//   -- Virtualiser RX/TX
//     -- Number of clients
//     -- mapping size, vaddr, set_vaddr=name
// -- Drivers
//   -- Board specific info, e.g. device phys addr, irq
//   -- mapping size, vaddr, set_vaddr=name

// TODO: potentially TOO generic, may need to split into serial_drivers, network_drivers, etc.
// instead of combining all into one.
var drivers: std.ArrayList(sDDFDefault.Driver) = undefined;
var components: std.ArrayList(sDDFDefault.Component) = undefined;

pub const sDDFDefault = struct {
    const Map = struct {
        /// Name of the memory mapping
        name: []const u8,
        /// Permissions to the memory mapping
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
        compatible: []const []const u8,
        maps: []const sDDFDefault.Map,
        irqs: []const sDDFDefault.Irq,
        channels: []const sDDFDefault.Channel,

        pub const Json = struct {
            name: []const u8,
            compatible: []const []const u8,
            maps: []const sDDFDefault.Map,
            irqs: []const sDDFDefault.Irq,
            channels: []const sDDFDefault.Channel,
        };

        pub fn fromJson(json: Json, class: []const u8) Driver {
            return .{
                .class = DeviceClass.fromStr(class),
                .name = json.name,
                .compatible = json.compatible,
                .maps = json.maps,
                .irqs = json.irqs,
                .channels = json.channels,
            };
        }
    };

    pub const Component = struct {
        class: DeviceClass,
        name: []const u8,
        maps: []const sDDFDefault.Map,
        channels: []const sDDFDefault.Channel,

        pub const Json = struct {
            name: []const u8,
            maps: []const sDDFDefault.Map,
            channels: []const sDDFDefault.Channel,
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

/// As part of the initilisation, we want to find all the JSON configuration
/// files, parse them, and built up a data structure for us to then search
/// through whenever we want to create a driver to the system description.
pub fn probe(allocator: Allocator, path: []const u8) !void {

}

pub const SerialSystem = struct {
    allocator: Allocator,
    board: MicrokitBoard,
    virt_rx: *Pd,
    virt_tx: *Pd,
    driver: *Pd,
    clients: std.ArrayList(*Pd),
    region_size: usize,
    page_size: Mr.PageSize,

    const REGIONS = [_][]const u8{ "data", "active", "free" };

    // TODO: Allow mapping info to be customisable by user
    pub fn create(allocator: Allocator, board: MicrokitBoard) SerialSystem {
        const system = SerialSystem{
            .allocator = allocator,
            .board = board,
            .clients = std.ArrayList(*Pd).init(allocator),
            .driver = undefined,
            .virt_rx = undefined,
            .virt_tx = undefined,
            .region_size = undefined,
            .page_size = undefined,
        };
        
        initDefault(allocator, &system);
        return system;
    }

    // These are default set up for the Serial System,
    // In the future, should read these from a JSON config file
    // instead of being hardcoded upon initialisation.
    fn initDefault(allocator: Allocator, system: *SerialSystem) void {
        // system.virt_rx = Pd.create(system.allocator, "serial_virt_rx", );
        // system.virt_tx = Pd.create(system.allocator, "serial_virt_tx", );
        // const driver_name = allocPrint(allocator, "driver_uart_{s}", .{system.board.driverPrefix()}) catch @panic("Could not create driver name");
        // switch (system.board.boardType) {
        //     MicrokitBoardType.qemu_arm_virt => {
        //         system.driver = Pd.create(system.allocator, driver_name, );
        //     },
        //     MicrokitBoardType.odroidc4 => {
        //         system.driver = Pd.create(system.allocator, driver_name, );
        //     },
        //     else => {
        //         @panic("Board not supported");
        //     }
        // }
        // system.region_size = 0x200_000;
        // system.page_size = SystemDescription.MemoryRegion.PageSize.optimal(system.board.arch(), system.region_size);
        _ = .{allocator, system};
    }

    pub fn setDriver(system: *SerialSystem, driver: *Pd) void {
        system.driver = driver;
    }

    pub fn setVirtualiser(system: *SerialSystem, virt_rx: *Pd, virt_tx: *Pd) void {
        system.virt_rx = virt_rx;
        system.virt_tx = virt_tx;
    }

    pub fn addClient(system: *SerialSystem, client: *Pd) void {
        system.clients.append(client) catch @panic("Could not add client to SerialSystem");
    }

    pub fn addToSystemDescription(system: *SerialSystem, sdf: SystemDescription) !void {
        _ = .{system, sdf};
    }
};