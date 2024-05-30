const std = @import("std");
const mod_sdf = @import("sdf.zig");
const mod_dtb = @import("dtb");
const mod_microkitboard = @import("microkitboard.zig");
const Allocator = std.mem.Allocator;

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

    // TODO: Allow mapping sizes to be customisable by user
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
        // These are default set up for the Serial System,
        // In the future, should read these from a JSON config file
        // instead of being hardcoded upon initialisation.
        switch (board.boardType) {
            MicrokitBoardType.qemu_arm_virt => {
                
            },
            MicrokitBoardType.odroidc4 => {

            },
            else => {
                // TODO: Don't panic instead return an error.BoardNotFound
                @panic("Board not supported");
            }
        }
        system.region_size = 0x200_000;
        system.page_size = SystemDescription.MemoryRegion.PageSize.optimal(board.arch(), system.region_size);
        return system;
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
    }
};