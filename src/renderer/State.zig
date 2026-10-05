//! This is the render state that is given to a renderer.

const State = @This();

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Inspector = @import("../inspector/main.zig").Inspector;
const terminalpkg = @import("../terminal/main.zig");
const inputpkg = @import("../input.zig");
const renderer = @import("../renderer.zig");
const unicode = @import("../unicode/main.zig");

/// The mutex that must be held while reading any of the data in the
/// members of this state. Note that the state itself is NOT protected
/// by the mutex and is NOT thread-safe, only the members values of the
/// state (i.e. the terminal, devmode, etc. values).
mutex: *std.Io.Mutex,

/// The terminal data.
terminal: *terminalpkg.Terminal,

/// The terminal inspector, if any. This will be null while the inspector
/// is not active and will be set when it is active.
inspector: ?*Inspector = null,

/// Input method composition displayed over the terminal cursor.
preedit: ?Preedit = null,

/// Mouse state. This only contains state relevant to what renderers
/// need about the mouse.
mouse: Mouse = .{},

/// The number of threads currently waiting to acquire `mutex` via
/// `lockDemand`. This is not protected by the mutex; it is read by
/// hot lock/unlock loops (the IO parse thread) in `yieldToDemand` to
/// decide whether to hand the mutex off before relocking it.
demand: std.atomic.Value(u32) = .init(0),

/// Handoff generation counter. Incremented (with a futex wake) by
/// `unlockDemand` after a demanding waiter releases the mutex, so that
/// `yieldToDemand` knows the waiter had its turn.
handoff_gen: std.atomic.Value(u32) = .init(0),

/// How long `yieldToDemand` sleeps waiting for a demanding waiter to
/// take its turn before giving up. This bounds how long the IO parse
/// thread can stall if a wake is lost or the waiter is descheduled; a
/// demanding critical section (the renderer's frame snapshot) is
/// microseconds, so one millisecond is generous.
const handoff_timeout_ns = 1 * std.time.ns_per_ms;

/// Acquire `mutex` while signaling demand for it. Use this instead of
/// locking the mutex directly on threads that must not be starved by
/// a hot lock/unlock loop (the renderer's frame snapshot). Must be
/// released with `unlockDemand`; releasing with `mutex.unlock` keeps
/// the data safe but makes parked `yieldToDemand` callers wait out
/// their full timeout.
///
/// Both `std.Thread.Mutex` and os_unfair_lock are unfair: a running
/// thread that unlocks and immediately relocks beats a sleeping
/// waiter every time, because the waiter must first be woken and
/// scheduled. Under sustained pty output the IO parse thread is
/// exactly such a loop, so without this signal the renderer can
/// starve for as long as the output lasts.
pub fn lockDemand(self: *State, io: std.Io) void {
    _ = self.demand.fetchAdd(1, .monotonic);
    self.mutex.lockUncancelable(io);
    const prev = self.demand.fetchSub(1, .monotonic);
    assert(prev > 0);
}

/// Release `mutex` acquired via `lockDemand` and notify hot loops
/// parked in `yieldToDemand` that the demanding waiter had its turn.
pub fn unlockDemand(self: *State, io: std.Io) void {
    self.mutex.unlock(io);
    _ = self.handoff_gen.fetchAdd(1, .monotonic);
    io.futexWake(@TypeOf(self.handoff_gen), &self.handoff_gen, 1);
}

/// Called by hot lock/unlock loops between critical sections, with
/// `mutex` NOT held: if a `lockDemand` waiter exists, sleep until it
/// has acquired and released the mutex (or the timeout passes). This
/// is the handoff that unfair mutexes never do on their own.
///
/// The orderings here are all monotonic because these atomics are a
/// scheduling heuristic, not a synchronization boundary: the mutex
/// itself orders the protected data, and the timeout bounds any
/// staleness.
pub fn yieldToDemand(self: *State, io: std.Io) void {
    if (self.demand.load(.monotonic) == 0) return;

    // Snapshot the generation before rechecking demand: if the waiter
    // acquires and releases between our check and the wait below, the
    // generation no longer matches and timedWait returns immediately.
    const gen = self.handoff_gen.load(.monotonic);
    if (self.demand.load(.monotonic) == 0) return;
    io.futexWaitTimeout(
        @TypeOf(self.handoff_gen),
        &self.handoff_gen,
        .init(gen),
        .{ .duration = .{ .raw = .fromNanoseconds(handoff_timeout_ns), .clock = .awake } },
    ) catch {};
}

pub const Mouse = struct {
    /// The point on the viewport where the mouse currently is. We use
    /// viewport points to avoid the complexity of mapping the mouse to
    /// the renderer state.
    point: ?terminalpkg.point.Coordinate = null,

    /// The mods that are currently active for the last mouse event.
    /// This could really just be mods in general and we probably will
    /// move it out of mouse state at some point.
    mods: inputpkg.Mods = .{},
};

/// The pre-edit state. See Surface.preeditCallback for more information.
pub const Preedit = struct {
    /// The codepoints to render as preedit text.
    codepoints: []const Codepoint = &.{},

    /// Insertion position in rendered codepoints. Null means the runtime
    /// did not provide a composition cursor.
    cursor: ?usize = null,

    /// A single codepoint to render as preedit text.
    pub const Codepoint = struct {
        codepoint: u21,
        wide: bool = false,
    };

    /// Convert UTF-8 composition text and its character offset to render state.
    pub fn init(alloc: Allocator, text: []const u8, cursor: ?usize) !Preedit {
        const view = try std.unicode.Utf8View.init(text);
        var it = view.iterator();
        var codepoints: std.ArrayList(Codepoint) = .empty;
        defer codepoints.deinit(alloc);
        var offset: usize = 0;
        var rendered_cursor: usize = 0;
        while (it.nextCodepoint()) |cp| {
            defer offset += 1;
            const w = unicode.table.get(cp).width;
            // Match the existing handling of zero-width preedit characters.
            if (w <= 0) continue;
            if (cursor) |pos| {
                if (offset < pos) rendered_cursor += 1;
            }
            try codepoints.append(alloc, .{ .codepoint = cp, .wide = w >= 2 });
        }
        return .{
            .codepoints = try codepoints.toOwnedSlice(alloc),
            .cursor = if (cursor != null) rendered_cursor else null,
        };
    }

    /// Deinit this preedit that was cre
    pub fn deinit(self: *const Preedit, alloc: Allocator) void {
        alloc.free(self.codepoints);
    }

    /// Allocate a copy of this preedit in the given allocator..
    pub fn clone(self: *const Preedit, alloc: Allocator) !Preedit {
        return .{
            .codepoints = try alloc.dupe(Codepoint, self.codepoints),
            .cursor = self.cursor,
        };
    }

    /// The width in cells of all codepoints in the preedit.
    pub fn width(self: *const Preedit) usize {
        var result: usize = 0;
        for (self.codepoints) |cp| {
            result += if (cp.wide) 2 else 1;
        }

        return result;
    }

    /// Range returns the start and end x position of the preedit text
    /// along with any codepoint offset necessary to fit the preedit
    /// into the available space.
    pub const Range = struct {
        start: terminalpkg.size.CellCountInt,
        end: terminalpkg.size.CellCountInt,
        cp_offset: usize,
        cp_end: usize,
    };

    pub fn range(
        self: *const Preedit,
        start: terminalpkg.size.CellCountInt,
        max: terminalpkg.size.CellCountInt,
    ) Range {
        if (self.cursor) |cursor| return self.cursorRange(start, max, cursor);
        // If our width is greater than the number of cells we have
        // then we need to adjust our codepoint start to a point where
        // our width would be less than the number of cells we have.
        const w, const cp_offset = width: {
            // max is inclusive, so we need to add 1 to it.
            const max_width = max - start + 1;

            // Rebuild our width in reverse order. This is because we want
            // to offset by the end cells, not the start cells (if we have to).
            var w: terminalpkg.size.CellCountInt = 0;
            for (0..self.codepoints.len) |i| {
                const reverse_i = self.codepoints.len - i - 1;
                const cp = self.codepoints[reverse_i];
                w += if (cp.wide) 2 else 1;
                if (w > max_width) {
                    break :width .{ w, reverse_i };
                }
            }

            // Width fit in the max width so no offset necessary.
            break :width .{ w, 0 };
        };

        // If our preedit goes off the end of the screen, we adjust it so
        // that it shifts left.
        const end = if (w > 0) start + (w - 1) else start;
        const start_offset = if (end > max) end - max else 0;
        return .{
            .start = start -| start_offset,
            .end = end -| start_offset,
            .cp_offset = cp_offset,
            .cp_end = self.codepoints.len,
        };
    }

    /// Keep the composition cursor visible when the text exceeds one row.
    /// Reserve a cell for the insertion position after the final character.
    fn cursorRange(self: *const Preedit, start: terminalpkg.size.CellCountInt, max: terminalpkg.size.CellCountInt, cursor: usize) Range {
        const max_width: usize = @as(usize, max) + 1;
        var w = self.width() + @intFromBool(cursor == self.codepoints.len);
        var first: usize = 0;
        var last = self.codepoints.len;
        while (w > max_width and first < cursor) : (first += 1) {
            w -= if (self.codepoints[first].wide) @as(usize, 2) else 1;
        }
        while (w > max_width and last > cursor + 1) {
            last -= 1;
            w -= if (self.codepoints[last].wide) @as(usize, 2) else 1;
        }
        const visible_width = @min(w, max_width);
        const origin: terminalpkg.size.CellCountInt = @intCast(@min(start, max_width - visible_width));
        return .{
            .start = origin,
            .end = origin + @as(terminalpkg.size.CellCountInt, @intCast(visible_width -| 1)),
            .cp_offset = first,
            .cp_end = last,
        };
    }

    pub fn cursorCell(self: *const Preedit, start: terminalpkg.size.CellCountInt, max: terminalpkg.size.CellCountInt) ?struct {
        x: terminalpkg.size.CellCountInt,
        wide: bool,
    } {
        const cursor = self.cursor orelse return null;
        const r = self.range(start, max);
        var x: usize = r.start;
        for (self.codepoints[r.cp_offset..cursor]) |cp| {
            x += if (cp.wide) @as(usize, 2) else 1;
        }
        return .{
            .x = @intCast(@min(x, max)),
            .wide = cursor < self.codepoints.len and self.codepoints[cursor].wide and max > 0,
        };
    }
};

const test_hangul_ga: u21 = 0xAC00; // U+AC00 HANGUL SYLLABLE GA

test "preedit cursor converts character offsets and survives cloning" {
    const testing = std.testing;
    const alloc = testing.allocator;
    // The combining accent is skipped by the existing preedit renderer.
    var p = try Preedit.init(alloc, "a\u{0301}你好b", 3);
    defer p.deinit(alloc);
    try testing.expectEqual(@as(?usize, 2), p.cursor);
    try testing.expectEqual(@as(usize, 4), p.codepoints.len);
    const cell = p.cursorCell(2, 19).?;
    try testing.expectEqual(@as(terminalpkg.size.CellCountInt, 5), cell.x);
    try testing.expect(cell.wide);
    const copy = try p.clone(alloc);
    defer copy.deinit(alloc);
    try testing.expectEqual(p.cursor, copy.cursor);
    try testing.expectEqualSlices(Preedit.Codepoint, p.codepoints, copy.codepoints);
}

test "preedit cursor clamps offsets and preserves runtimes without a cursor" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const p = try Preedit.init(alloc, "你好", 99);
    defer p.deinit(alloc);
    try testing.expectEqual(@as(?usize, 2), p.cursor);
    try testing.expectEqual(@as(terminalpkg.size.CellCountInt, 4), p.cursorCell(0, 9).?.x);
    try testing.expect(!p.cursorCell(0, 9).?.wide);
    const no_cursor = try Preedit.init(alloc, "你好", null);
    defer no_cursor.deinit(alloc);
    try testing.expect(no_cursor.cursorCell(0, 9) == null);
    try testing.expectError(error.InvalidUtf8, Preedit.init(alloc, "\xff", 0));
}

test "preedit cursor reserves a cell after wide text at the right edge" {
    const testing = std.testing;
    const p: Preedit = .{
        .codepoints = &.{.{ .codepoint = test_hangul_ga, .wide = true }},
        .cursor = 1,
    };
    const r = p.range(9, 9);
    try testing.expectEqual(@as(terminalpkg.size.CellCountInt, 7), r.start);
    try testing.expectEqual(@as(terminalpkg.size.CellCountInt, 9), r.end);
    try testing.expectEqual(@as(terminalpkg.size.CellCountInt, 9), p.cursorCell(9, 9).?.x);
}

test "preedit cursor stays visible when navigating clipped wide text" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var p = try Preedit.init(alloc, "你好世界", 4);
    defer p.deinit(alloc);
    const tail = p.range(3, 3);
    try testing.expectEqual(@as(usize, 3), tail.cp_offset);
    try testing.expectEqual(@as(terminalpkg.size.CellCountInt, 3), p.cursorCell(3, 3).?.x);
    p.cursor = 0;
    const head = p.range(3, 3);
    try testing.expectEqual(@as(usize, 0), head.cp_offset);
    try testing.expectEqual(@as(usize, 2), head.cp_end);
    try testing.expectEqual(@as(terminalpkg.size.CellCountInt, 0), p.cursorCell(3, 3).?.x);
    p.cursor = 2;
    const middle = p.range(3, 3);
    try testing.expectEqual(@as(usize, 2), middle.cp_offset);
    try testing.expectEqual(@as(terminalpkg.size.CellCountInt, 0), p.cursorCell(3, 3).?.x);
}

test "preedit range covers exact cell width" {
    const testing = std.testing;

    {
        const p: Preedit = .{
            .codepoints = &.{.{ .codepoint = 'a' }},
        };
        const range = p.range(2, 9);
        try testing.expectEqual(@as(terminalpkg.size.CellCountInt, 2), range.start);
        try testing.expectEqual(@as(terminalpkg.size.CellCountInt, 2), range.end);
        try testing.expectEqual(@as(usize, 0), range.cp_offset);
    }

    {
        const p: Preedit = .{
            .codepoints = &.{.{ .codepoint = test_hangul_ga, .wide = true }},
        };
        const range = p.range(2, 9);
        try testing.expectEqual(@as(terminalpkg.size.CellCountInt, 2), range.start);
        try testing.expectEqual(@as(terminalpkg.size.CellCountInt, 3), range.end);
        try testing.expectEqual(@as(usize, 0), range.cp_offset);
    }
}

test "preedit range shifts left at right edge" {
    const testing = std.testing;

    const p: Preedit = .{
        .codepoints = &.{.{ .codepoint = test_hangul_ga, .wide = true }},
    };
    const range = p.range(9, 9);
    try testing.expectEqual(@as(terminalpkg.size.CellCountInt, 8), range.start);
    try testing.expectEqual(@as(terminalpkg.size.CellCountInt, 9), range.end);
    try testing.expectEqual(@as(usize, 0), range.cp_offset);
}
