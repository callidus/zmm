const std = @import("std");
const sys = std.os.system;

var buf: [1048]u8 = undefined; // resp buffer for MPD comms
var state: std.StringHashMap([]const u8) = undefined; // MPD state values

// how long in mins to wait sleep for. We will check ever interval to see if we
// have had no status updates from MPD and that MPD is not currently playing. If
// this check passes then we set the GPIO pin low. Basically turn off the amp
// after at least this long and at most twice this long with no activity.
const SLEEP_TIME_MINS = 3;

// details for the GPIO pin we want to control
const GPIO_PIN = "14";
const GPIO_DIR_PATH = "/sys/class/gpio/gpio14/direction";
const GPIO_VAL_PATH = "/sys/class/gpio/gpio14/value";

const flags = std.fs.File.OpenFlags{ .mode = std.fs.File.OpenMode.write_only };
const State = enum { GPIO_HIGH, GPIO_LOW };

// Export the desired pin by writing to /sys/class/gpio/export
fn exportGPIO() !void {
    std.log.info("Export GPIO pin {s}", .{GPIO_PIN});
    const file = try std.fs.openFileAbsolute("/sys/class/gpio/export", flags);
    defer file.close();

    try file.writeAll(GPIO_PIN);
}

// Set the pin to be an output by writing "out" to /sys/class/gpio/gpio24/direction
fn setGPIODirection() !void {
    std.log.info("Set GPIO pin {s} direction", .{GPIO_PIN});
    const file = try std.fs.openFileAbsolute(GPIO_DIR_PATH, flags);
    defer file.close();

    try file.writeAll("out");
}

// Export the desired pin by writing to /sys/class/gpio/unexport
fn unexportGPIO() !void {
    std.log.info("Unexport GPIO pin {s}", .{GPIO_PIN});
    const file = try std.fs.openFileAbsolute("/sys/class/gpio/unexport", flags);
    defer file.close();

    try file.writeAll(GPIO_PIN);
}

// set the GPIO pin high or low
fn setGPIOValue(val: State) !void {
    const vstr = if (val == State.GPIO_HIGH) "1" else "0";
    std.log.info("Set GPIO pin {s} value {s}", .{ GPIO_PIN, vstr });

    const file = try std.fs.openFileAbsolute(GPIO_VAL_PATH, flags);
    defer file.close();

    try file.writeAll(vstr);
}

// send a message to MPD, wait for the response (blocking)
fn messageMPD(msg: []const u8, ret: []u8, strm: std.net.Stream) !usize {
    std.log.info("MPD Send: {s}", .{msg});

    _ = try strm.write(msg);
    var num = try strm.read(ret[0..]);

    std.log.info("MPD Read ({}): {s}", .{ num, buf[0..num] });
    return num;
}

// parse a block of state data from MPD into a hash map
fn parseState(data: []const u8) !void {
    var readIter = std.mem.tokenize(u8, data, "\n");
    while (readIter.next()) |line| {
        if (std.mem.indexOf(u8, line, ":")) |at| {
            try state.put(line[0..at], line[at + 2 ..]);
        }
    }
}

var alive: bool = false;
var mutex: std.Thread.Mutex = .{};
var messageCount: u32 = 0;
// monitor MPD for "player" state changes, blocking, thread safe
fn monitorMPD(strm: std.net.Stream) !void {
    var num: usize = 0;
    defer _ = messageMPD("noidle\n", buf[0..], strm) catch unreachable;

    while (alive) {
        _ = try messageMPD("idle player\n", buf[0..], strm);
        num = try messageMPD("status\n", buf[0..], strm);

        if (num > 0) {
            mutex.lock();
            defer mutex.unlock();

            messageCount = messageCount + 1;
            try parseState(buf[0..num]);
            if (state.get("state")) |s| {
                std.log.info("MPD State: '{s}'", .{s});
                if (std.mem.eql(u8, s, "play")) {
                    try setGPIOValue(State.GPIO_HIGH);
                }
            }
        }
    }
}

// spawn a thread, connect to MPD and monitor
fn connectMPD() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    state = std.StringHashMap([]const u8).init(gpa.allocator());
    defer state.deinit();
    defer _ = gpa.deinit();

    // you could point this at another MPD, but I use it on the same host
    const addr = std.net.Address.initIp4([4]u8{ 127, 0, 0, 1 }, 6600);
    const conn = try std.net.tcpConnectToAddress(addr);
    defer conn.close();

    var num = try conn.read(buf[0..]);
    if (num > 0) {
        std.log.info("Connect: {s}", .{buf[0..num]});
    }

    alive = true;
    num = try messageMPD("status\n", buf[0..], conn);
    try parseState(buf[0..num]);
    try monitorMPD(conn);
}

// sleep for a bit, if no updates from MPD in that time and its not playing anything
// set the GPIO pin low and go back to sleep, thread safe, blocking
fn timeoutLogic() !void {
    var lastCount = messageCount;
    while (true) {
        std.time.sleep(std.time.ns_per_min * SLEEP_TIME_MINS);

        mutex.lock();
        if (lastCount == messageCount) { // no update on monitor thread
            if (state.get("state")) |s| {
                if (std.mem.eql(u8, s, "pause") or std.mem.eql(u8, s, "stop")) {
                    std.log.info("Powerintg down", .{});
                    try setGPIOValue(State.GPIO_LOW);
                }
            }
        } else {
            lastCount = messageCount;
        }
        mutex.unlock();
    }
}

pub fn main() !void {
    try exportGPIO();
    defer unexportGPIO() catch {};

    try setGPIODirection();

    try setGPIOValue(State.GPIO_LOW);
    defer setGPIOValue(State.GPIO_LOW) catch {};

    // connect to MPD and monitor for state changes using a thread
    _ = try std.Thread.spawn(.{}, connectMPD, .{});
    try timeoutLogic();
}
