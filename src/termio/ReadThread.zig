/// Blocking PTY reader thread.
///
/// Runs a tight blocking read loop on the PTY output stream, processing VT
/// data under the render lock.
///
/// This is critical for resize: some PTY backends emit a redraw when the grid
/// size changes. The pending read on this thread keeps output draining while
/// the writer thread applies the resize.
///
/// Shutdown is delegated to the platform PTY backend.
const std = @import("std");
const Command = @import("../Command.zig");
const Surface = @import("../Surface.zig");
const window_backend = @import("../platform/window_backend.zig");
const read_coalesce = @import("read_coalesce.zig");
const io_log = std.log.scoped(.surface_io);

/// Large reads keep the per-chunk overhead (render-lock acquisition, VT parse
/// setup, OSC/agent scans, UI wakeup) off the hot path during output floods:
/// fewer, bigger chunks instead of thousands of 4KB ones. Both PTY backends
/// accept arbitrary buffer sizes.
const READ_BUF_SIZE = 64 * 1024;

/// After PTY EOF/EIO, retry waitpid this long so a single WNOHANG cannot
/// leave a defunct child. Short enough that a process which closed the
/// slave and kept running cannot hang the reader thread.
const CHILD_REAP_TIMEOUT_MS: u64 = 250;

/// A PTY backend can report end-of-stream (or fail a read) for reasons that
/// say nothing about the child process: a backend may hand back a short/empty
/// read or a broken pipe while the shell is still running — observed when a
/// foreground TUI such as `opencode` exits. Treating that as "the session
/// ended" tore down the reader and (via the close-on-exit sweep) the whole tab.
/// So before claiming an exit we ask the OS whether the child is really gone;
/// if it is not, the read is retried after a short sleep.
const TRANSIENT_RETRY_SLEEP_MS: u64 = 20;

/// Retry budget for consecutive unproven end-of-stream/read failures, i.e. how
/// long a live child may keep the reader in the retry state before we give up
/// on the PTY (5s). On exhaustion we stop reading *without* claiming the child
/// exited, so the pane stays instead of being closed.
const MAX_TRANSIENT_RETRIES: u32 = 250;

pub const Recovery = enum {
    /// The OS confirmed the child exited: record the exit and stop reading.
    exit_now,
    /// The child is still running, so this was a backend hiccup: sleep and
    /// read again.
    retry,
    /// The child is still running but the PTY never recovered: stop reading
    /// without claiming an exit, leaving the pane in place.
    stop_without_exit,
};

/// Classify an end-of-stream/read failure. `child_exited` is true only when
/// `Surface.pollExitStatus` returned an exit status; `transient_streak` counts
/// consecutive failures that carried no such proof.
pub fn classifyReadEnd(child_exited: bool, transient_streak: u32) Recovery {
    if (child_exited) return .exit_now;
    if (transient_streak < MAX_TRANSIENT_RETRIES) return .retry;
    return .stop_without_exit;
}

pub fn threadMain(surface: *Surface) void {
    defer surface.markStopped();

    var buf: [READ_BUF_SIZE]u8 = undefined;
    var resize_pending: std.ArrayListUnmanaged(u8) = .empty;
    defer resize_pending.deinit(surface.allocator);
    var output_pending: std.ArrayListUnmanaged(u8) = .empty;
    defer output_pending.deinit(surface.allocator);
    var transient_streak: u32 = 0;

    while (!surface.exited.load(.acquire)) {
        const bytes_read = surface.pty.readOutput(&buf) catch |err| {
            switch (handleReadError(surface, err, &transient_streak)) {
                .retry => continue,
                .stop => return,
            }
        };
        if (bytes_read == 0) {
            if (handleEndOfStream(surface, &transient_streak)) return;
            continue;
        }
        transient_streak = 0;

        const data = buf[0..bytes_read];
        if (surface.remote_client) |client| {
            client.sendOutput(surface.remote_id[0..], data);
        }

        if (surface.resize_in_progress.load(.acquire)) {
            resize_pending.appendSlice(surface.allocator, data) catch {
                resize_pending.clearRetainingCapacity();
            };
            drainResizeOutput(surface, &resize_pending, &buf, &transient_streak);
            if (resize_pending.items.len == 0) continue;
            processOutput(surface, resize_pending.items);
            resize_pending.clearRetainingCapacity();
            if (markExitedIfProcessEndedAfterOutput(surface)) return;
            continue;
        }

        if (resize_pending.items.len > 0) {
            resize_pending.appendSlice(surface.allocator, data) catch {
                processOutput(surface, resize_pending.items);
                resize_pending.clearRetainingCapacity();
                processOutputCoalesced(surface, data, &output_pending, &buf, &transient_streak);
                if (markExitedIfProcessEndedAfterOutput(surface)) return;
                continue;
            };
            processOutput(surface, resize_pending.items);
            resize_pending.clearRetainingCapacity();
            if (markExitedIfProcessEndedAfterOutput(surface)) return;
        } else {
            processOutputCoalesced(surface, data, &output_pending, &buf, &transient_streak);
            if (markExitedIfProcessEndedAfterOutput(surface)) return;
        }
    }
}

/// Handle a PTY end-of-stream seen by the main loop or a drain helper. Returns
/// true when the reader should stop; false means "this was spurious, keep
/// reading". The exit is only recorded once the OS confirms the child is gone.
fn handleEndOfStream(surface: *Surface, transient_streak: *u32) bool {
    switch (classifyReadEnd(surface.pollExitStatus() != null, transient_streak.*)) {
        .exit_now => {
            if (!surface.exited.load(.acquire)) {
                surface.markExited(.eof, surface.command.waitUntilReaped(CHILD_REAP_TIMEOUT_MS));
            }
            return true;
        },
        .retry => {
            transient_streak.* += 1;
            std.Thread.sleep(TRANSIENT_RETRY_SLEEP_MS * std.time.ns_per_ms);
            return false;
        },
        .stop_without_exit => {
            io_log.warn("pty end-of-stream with a live child after {d} retries; keeping the pane", .{transient_streak.*});
            return true;
        },
    }
}

fn drainResizeOutput(
    surface: *Surface,
    pending: *std.ArrayListUnmanaged(u8),
    scratch: *[READ_BUF_SIZE]u8,
    transient_streak: *u32,
) void {
    while (surface.resize_in_progress.load(.acquire) and !surface.exited.load(.acquire)) {
        const available = surface.pty.outputAvailable() orelse return;

        if (available == 0) {
            std.Thread.sleep(std.time.ns_per_ms);
            continue;
        }

        const to_read = @min(available, scratch.len);
        const bytes_read = surface.pty.readOutput(scratch[0..to_read]) catch |err| switch (handleReadError(surface, err, transient_streak)) {
            .retry => continue,
            .stop => return,
        };

        if (bytes_read == 0) {
            _ = handleEndOfStream(surface, transient_streak);
            return;
        }

        const data = scratch[0..bytes_read];
        if (surface.remote_client) |client| {
            client.sendOutput(surface.remote_id[0..], data);
        }
        pending.appendSlice(surface.allocator, data) catch {
            pending.clearRetainingCapacity();
            return;
        };
    }
}

fn processOutputCoalesced(
    surface: *Surface,
    first: []const u8,
    pending: *std.ArrayListUnmanaged(u8),
    scratch: *[READ_BUF_SIZE]u8,
    transient_streak: *u32,
) void {
    if (first.len == 0) return;

    pending.clearRetainingCapacity();
    pending.appendSlice(surface.allocator, first) catch {
        processOutput(surface, first);
        return;
    };

    drainAvailableOutput(surface, pending, scratch, transient_streak);
    processOutput(surface, pending.items);
}

fn drainAvailableOutput(
    surface: *Surface,
    pending: *std.ArrayListUnmanaged(u8),
    scratch: *[READ_BUF_SIZE]u8,
    transient_streak: *u32,
) void {
    while (!surface.exited.load(.acquire)) {
        const available = surface.pty.outputAvailable() orelse return;
        const to_read = read_coalesce.nextDrainLen(available, scratch.len, pending.items.len);
        if (to_read == 0) return;

        const bytes_read = surface.pty.readOutput(scratch[0..to_read]) catch |err| switch (handleReadError(surface, err, transient_streak)) {
            .retry => continue,
            .stop => return,
        };
        if (bytes_read == 0) {
            _ = handleEndOfStream(surface, transient_streak);
            return;
        }

        const data = scratch[0..bytes_read];
        if (surface.remote_client) |client| {
            client.sendOutput(surface.remote_id[0..], data);
        }
        pending.appendSlice(surface.allocator, data) catch {
            processOutput(surface, pending.items);
            pending.clearRetainingCapacity();
            processOutput(surface, data);
            return;
        };
    }
}

fn processOutput(surface: *Surface, data: []const u8) void {
    if (data.len == 0) return;

    surface.render_state.mutex.lock();
    defer surface.render_state.mutex.unlock();

    surface.resetOscBatch();
    surface.feedVtWithWispTermImageFallback(data);
    surface.scanForOscTitle(data);
    // One wakeup per UI consume cycle is enough — the render loop drains all
    // pending output on a single frame; per-chunk posts only flood the
    // platform event queue during output bursts.
    if (surface.markOutputDirty()) window_backend.postWakeup();
}

const ExitAfterOutput = struct {
    available: ?usize,
    status: ?Command.Exit,
};

fn shouldMarkExitedAfterOutput(sample: ExitAfterOutput) bool {
    return sample.available != null and sample.available.? == 0 and sample.status != null;
}

fn markExitedIfProcessEndedAfterOutput(surface: *Surface) bool {
    const available = surface.pty.outputAvailable();
    if (available == null or available.? != 0) return false;

    const status = surface.pollExitStatus() orelse return false;
    if (!shouldMarkExitedAfterOutput(.{ .available = available, .status = status })) return false;

    surface.markExited(.eof, status);
    return true;
}

const ReadErrorAction = enum { retry, stop };

/// A read error is only evidence of a finished session if the OS agrees the
/// child is gone. A backend hiccup (a broken pipe / short read while a
/// foreground TUI such as `opencode` is running or just exited) leaves the
/// shell alive, so we retry instead of tearing the pane down. Only after the
/// retry budget is exhausted does an unrecovered error become an IO failure.
fn handleReadError(surface: *Surface, err: anyerror, transient_streak: *u32) ReadErrorAction {
    if (err == error.ReadInterrupted) {
        return if (surface.exited.load(.acquire)) .stop else .retry;
    }

    if (surface.exited.load(.acquire)) return .stop;

    switch (classifyReadEnd(surface.pollExitStatus() != null, transient_streak.*)) {
        .exit_now => {
            surface.markExited(.broken_pipe, surface.command.waitUntilReaped(CHILD_REAP_TIMEOUT_MS));
            return .stop;
        },
        .retry => {
            transient_streak.* += 1;
            std.Thread.sleep(TRANSIENT_RETRY_SLEEP_MS * std.time.ns_per_ms);
            return .retry;
        },
        .stop_without_exit => {
            surface.failIo(.pty_read, err);
            return .stop;
        },
    }
}

test "read thread marks process exit after drained output only" {
    try std.testing.expect(shouldMarkExitedAfterOutput(.{ .available = 0, .status = Command.Exit{ .exited = 0 } }));
    try std.testing.expect(!shouldMarkExitedAfterOutput(.{ .available = 12, .status = Command.Exit{ .exited = 0 } }));
    try std.testing.expect(!shouldMarkExitedAfterOutput(.{ .available = 0, .status = null }));
    try std.testing.expect(!shouldMarkExitedAfterOutput(.{ .available = null, .status = Command.Exit{ .exited = 0 } }));
}

test "read thread only claims an exit once the OS confirms the child died" {
    // No exit status: the PTY said end-of-stream but the shell is still
    // running, so the reader retries instead of killing the session.
    try std.testing.expectEqual(Recovery.retry, classifyReadEnd(false, 0));
    try std.testing.expectEqual(Recovery.retry, classifyReadEnd(false, MAX_TRANSIENT_RETRIES - 1));

    // Confirmed exit: record it and stop, exactly as before.
    try std.testing.expectEqual(Recovery.exit_now, classifyReadEnd(true, 0));
    try std.testing.expectEqual(Recovery.exit_now, classifyReadEnd(true, MAX_TRANSIENT_RETRIES));

    // Budget exhausted with a live child: stop reading but leave the exit
    // unclaimed, so the close-on-exit sweep keeps the pane.
    try std.testing.expectEqual(Recovery.stop_without_exit, classifyReadEnd(false, MAX_TRANSIENT_RETRIES));
}

