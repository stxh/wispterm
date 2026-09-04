//! Headless tmux control-mode controller. Consumes the Phase 1 parsers
//! (`control`, `layout`), maintains a window/pane model from pushed
//! notifications, queues outbound tmux commands, and delivers pane output
//! through a `PaneSink`. No Surface / PTY / fd dependency — Phase 3 wires those
//! across the sink and `sendKeys` seams.

const std = @import("std");
const Allocator = std.mem.Allocator;
const control = @import("control.zig");
const layout = @import("layout.zig");

/// Receives unescaped pane output bytes. Phase 3 backs this with a virtual PTY
/// feeding a Surface; tests back it with a per-pane collector. `bytes` is only
/// valid for the duration of the call.
pub const PaneSink = struct {
    ctx: *anyopaque,
    writeFn: *const fn (ctx: *anyopaque, pane_id: usize, bytes: []const u8) void,

    pub fn write(self: PaneSink, pane_id: usize, bytes: []const u8) void {
        self.writeFn(self.ctx, pane_id, bytes);
    }
};

pub const Session = struct {
    alloc: Allocator,
    parser: control.Parser,
    sink: PaneSink,
    cols: u16,
    rows: u16,
    cmds: std.ArrayListUnmanaged(u8) = .empty,
    scratch: std.ArrayListUnmanaged(u8) = .empty,
    windows: std.ArrayListUnmanaged(Window) = .empty,
    pane_states: std.ArrayListUnmanaged(PaneState) = .empty,
    /// FIFO of replies expected from commands we have sent to tmux. Command
    /// replies arrive in order, but bootstrap reconciliation can enqueue
    /// capture-pane commands before earlier list-panes replies have arrived; a
    /// typed FIFO keeps an empty/error list-panes reply from stealing a capture
    /// seed and leaving a reattached pane blank.
    reply_queue: std.ArrayListUnmanaged(ReplyKind) = .empty,
    active_window: ?usize = null,
    active_pane: ?usize = null,
    exited: bool = false,
    /// Set when a command reply is a `%error` whose body says the attach target
    /// is gone ("can't find session" / "no sessions"). On a reconnect `attach`
    /// this means the user genuinely ended the session, so the controller closes
    /// rather than looping reconnects. Distinct from `exited` (which also fires on
    /// a survivable transport drop). Reset by `resetForReconnect`.
    session_gone: bool = false,
    events: EventSink = .{},

    pub const CaptureScreen = enum { primary, alternate };

    const PaneState = struct {
        pane_id: usize,
        pending: bool = false,
        alternate_on: bool = false,
        alternate_saved_x: ?usize = null,
        alternate_saved_y: ?usize = null,
        /// VT controls that reconcile the fresh/reused Surface with tmux's
        /// pane modes. Applied only after the active screen capture is seeded,
        /// otherwise a restored scroll region can corrupt the seed itself.
        restore: std.ArrayListUnmanaged(u8) = .empty,

        fn deinit(self: *PaneState, alloc: Allocator) void {
            self.restore.deinit(alloc);
        }
    };

    const CaptureRequest = struct {
        pane_id: usize,
        screen: CaptureScreen,
    };

    const PaneStateRequest = struct {
        capture: bool = false,
        pane_id: ?usize = null,
    };

    const ReplyKind = union(enum) {
        ignore,
        window_list,
        pane_list,
        pane_state: PaneStateRequest,
        capture: CaptureRequest,
    };

    pub const Window = struct {
        id: usize,
        active: bool = false,
        name: std.ArrayListUnmanaged(u8) = .empty,
        panes: std.ArrayListUnmanaged(usize) = .empty,

        fn deinit(self: *Window, alloc: Allocator) void {
            self.name.deinit(alloc);
            self.panes.deinit(alloc);
        }
    };

    /// High-level model events for the UI bridge (Phase 3c-2). The mirror of
    /// `PaneSink`: the controller is Surface-agnostic, so it pushes typed events
    /// to a sink the bridge backs with tab/Surface side effects. All callbacks
    /// are best-effort (`void`) — the bridge handles its own allocation
    /// failures, like `PaneSink.write`. `root`/`name` are only valid for the
    /// duration of the call. The default sink ignores everything (headless/unit
    /// use).
    pub const EventSink = struct {
        ctx: *anyopaque = undefined,
        onLayoutChange: *const fn (ctx: *anyopaque, window_id: usize, root: *const layout.Node) void = noLayout,
        onWindowRenamed: *const fn (ctx: *anyopaque, window_id: usize, name: []const u8) void = noRename,
        onWindowClose: *const fn (ctx: *anyopaque, window_id: usize) void = noClose,
        onActiveWindowChanged: *const fn (ctx: *anyopaque, window_id: usize) void = noActiveWindow,
        onActivePaneChanged: *const fn (ctx: *anyopaque, pane_id: usize) void = noActive,
        onPaneMeta: *const fn (ctx: *anyopaque, pane_id: usize, path: []const u8, cmd: []const u8) void = noPaneMeta,

        fn noLayout(_: *anyopaque, _: usize, _: *const layout.Node) void {}
        fn noRename(_: *anyopaque, _: usize, _: []const u8) void {}
        fn noClose(_: *anyopaque, _: usize) void {}
        fn noActiveWindow(_: *anyopaque, _: usize) void {}
        fn noActive(_: *anyopaque, _: usize) void {}
        fn noPaneMeta(_: *anyopaque, _: usize, _: []const u8, _: []const u8) void {}
    };

    pub fn init(alloc: Allocator, sink: PaneSink, cols: u16, rows: u16) Session {
        return .{
            .alloc = alloc,
            .parser = control.Parser.init(alloc),
            .sink = sink,
            .cols = cols,
            .rows = rows,
        };
    }

    pub fn deinit(self: *Session) void {
        self.parser.deinit();
        self.cmds.deinit(self.alloc);
        self.scratch.deinit(self.alloc);
        self.reply_queue.deinit(self.alloc);
        self.clearPaneStates();
        self.pane_states.deinit(self.alloc);
        for (self.windows.items) |*w| w.deinit(self.alloc);
        self.windows.deinit(self.alloc);
    }

    pub fn windowCount(self: *const Session) usize {
        return self.windows.items.len;
    }

    pub fn pendingCommands(self: *const Session) []const u8 {
        return self.cmds.items;
    }

    pub fn clearCommands(self: *Session) void {
        self.cmds.clearRetainingCapacity();
    }

    /// Reset transient stream state for a transport reconnect: the byte parser
    /// (the dropped stream may have left a partial line), the outbound command
    /// queue, and the pending command-reply FIFO. The window/pane model is kept —
    /// the post-reconnect `list-windows` refreshes it and the bridge reuses the
    /// same surfaces by pane id.
    pub fn resetForReconnect(self: *Session) void {
        self.parser.deinit();
        self.parser = control.Parser.init(self.alloc);
        self.cmds.clearRetainingCapacity();
        self.reply_queue.clearRetainingCapacity();
        // The reused Surfaces must be reconciled from the newly attached tmux
        // client, not from terminal modes cached before the transport dropped.
        self.clearPaneStates();
        self.exited = false;
        self.session_gone = false;
    }

    pub fn feed(self: *Session, bytes: []const u8) Allocator.Error!void {
        for (bytes) |b| {
            if (try self.parser.put(b)) |n| try self.handle(n);
        }
    }

    fn handle(self: *Session, n: control.Notification) Allocator.Error!void {
        switch (n) {
            .output => |o| {
                self.scratch.clearRetainingCapacity();
                try control.unescape(self.alloc, &self.scratch, o.data);
                self.sink.write(o.pane_id, self.scratch.items);
            },
            .layout_change => |lc| try self.applyLayout(lc.window_id, lc.layout),
            // A command-reply block. On attach tmux does NOT emit
            // %layout-change, so the initial windows/layouts are learned from
            // the `list-windows` reply. Prefer the command FIFO populated when
            // commands are queued; fall back to content sniffing only for unit
            // fixtures or unexpected untracked replies.
            .block_end => |body| try self.handleBlockEnd(body),
            .block_err => |body| {
                // A reconnect `attach` to a session the user ended replies with a
                // `%error` whose body names the failure; flag it so the controller
                // tears down instead of recreating the session.
                if (isSessionGoneError(body)) self.session_gone = true;
                // Pop the matching command reply, but do not let non-capture
                // errors consume any later capture seed.
                if (self.popReply()) |reply| self.finishFailedReply(reply);
            },
            .window_add => |w| _ = try self.ensureWindow(w.window_id),
            .window_renamed => |w| {
                try self.renameWindow(w.window_id, w.name);
                self.events.onWindowRenamed(self.events.ctx, w.window_id, w.name);
            },
            .window_close => |w| {
                self.events.onWindowClose(self.events.ctx, w.window_id);
                self.removeWindow(w.window_id);
            },
            .window_pane_changed => |w| {
                self.active_window = w.window_id;
                self.active_pane = w.pane_id;
                self.events.onActivePaneChanged(self.events.ctx, w.pane_id);
            },
            .exit => self.exited = true,
            else => {},
        }
    }

    pub fn findWindow(self: *Session, id: usize) ?*Window {
        for (self.windows.items) |*w| {
            if (w.id == id) return w;
        }
        return null;
    }

    fn ensureWindow(self: *Session, id: usize) Allocator.Error!*Window {
        if (self.findWindow(id)) |w| return w;
        try self.windows.append(self.alloc, .{ .id = id });
        return &self.windows.items[self.windows.items.len - 1];
    }

    fn renameWindow(self: *Session, id: usize, name: []const u8) Allocator.Error!void {
        const w = try self.ensureWindow(id);
        w.name.clearRetainingCapacity();
        try w.name.appendSlice(self.alloc, name);
    }

    fn removeWindow(self: *Session, id: usize) void {
        var i: usize = 0;
        while (i < self.windows.items.len) : (i += 1) {
            if (self.windows.items[i].id == id) {
                self.windows.items[i].deinit(self.alloc);
                _ = self.windows.orderedRemove(i);
                if (self.active_window == id) self.active_window = null;
                return;
            }
        }
    }

    fn enqueueCommand(self: *Session, command: []const u8, reply: ReplyKind) Allocator.Error!void {
        const old_len = self.cmds.items.len;
        errdefer self.cmds.items.len = old_len;

        try self.cmds.appendSlice(self.alloc, command);
        try self.reply_queue.append(self.alloc, reply);
    }

    fn popReply(self: *Session) ?ReplyKind {
        if (self.reply_queue.items.len == 0) return null;
        return self.reply_queue.orderedRemove(0);
    }

    fn dropLeadingIgnoredReplies(self: *Session) void {
        while (self.reply_queue.items.len > 0 and std.meta.activeTag(self.reply_queue.items[0]) == .ignore) {
            _ = self.reply_queue.orderedRemove(0);
        }
    }

    fn takeFirstWindowListReply(self: *Session) bool {
        for (self.reply_queue.items, 0..) |reply, i| {
            if (std.meta.activeTag(reply) == .window_list) {
                _ = self.reply_queue.orderedRemove(i);
                return true;
            }
        }
        return false;
    }

    fn takeFirstPaneListReply(self: *Session) bool {
        for (self.reply_queue.items, 0..) |reply, i| {
            if (std.meta.activeTag(reply) == .pane_list) {
                _ = self.reply_queue.orderedRemove(i);
                return true;
            }
        }
        return false;
    }

    fn handleBlockEnd(self: *Session, body: []const u8) Allocator.Error!void {
        // tmux may emit empty replies for commands whose output we do not care
        // about (for example size refreshes). Do not let those stale ignored
        // replies offset later list/capture routing.
        if (std.mem.trim(u8, body, " \r\n\t").len == 0) {
            if (self.reply_queue.items.len > 0) {
                switch (self.reply_queue.items[0]) {
                    .ignore, .window_list, .pane_list => _ = self.popReply(),
                    .pane_state => {
                        const reply = self.popReply().?;
                        self.finishFailedReply(reply);
                    },
                    .capture => |cap| {
                        _ = self.popReply();
                        try self.seedCapturePane(cap.pane_id, cap.screen, body);
                    },
                }
            }
            return;
        }

        if (isPaneListReply(body)) {
            self.dropLeadingIgnoredReplies();
            _ = self.takeFirstPaneListReply();
            _ = try self.applyPaneList(body);
            return;
        }

        if (isWindowListReply(body)) {
            self.dropLeadingIgnoredReplies();
            _ = self.takeFirstWindowListReply();
            _ = try self.applyWindowList(body);
            return;
        }

        if (self.popReply()) |reply| {
            switch (reply) {
                .ignore => {},
                .window_list => _ = try self.applyWindowList(body),
                .pane_list => _ = try self.applyPaneList(body),
                .pane_state => |req| _ = try self.applyPaneState(body, req),
                .capture => |cap| try self.seedCapturePane(cap.pane_id, cap.screen, body),
            }
            return;
        }

        if (!try self.applyWindowList(body)) {
            if (isPaneListReply(body)) _ = try self.applyPaneList(body);
        }
    }

    fn finishFailedReply(self: *Session, reply: ReplyKind) void {
        switch (reply) {
            .pane_state => |req| {
                if (req.pane_id) |pane_id| self.removePendingPaneState(pane_id);
            },
            else => {},
        }
    }

    fn seedCapturePane(self: *Session, pane_id: usize, screen: CaptureScreen, body: []const u8) Allocator.Error!void {
        if (isPaneListReply(body)) {
            _ = try self.applyPaneList(body);
            return;
        }
        if (isWindowListReply(body)) {
            _ = try self.applyWindowList(body);
            return;
        }

        // Repaint from the top-left, translating LF→CRLF: the capture's rows
        // are joined by '\n' only, and the terminal's line feed moves down
        // without returning to column 0 — without the '\r' each row staircases.
        self.scratch.clearRetainingCapacity();
        try self.scratch.appendSlice(self.alloc, if (screen == .alternate) "\x1b[?1049h" else "\x1b[?1049l");
        // capture-pane -e describes cell attributes, not the pane's current
        // rendition. Reset before clearing and again after the final cell so a
        // captured background cannot leak into later live output.
        try self.scratch.appendSlice(self.alloc, "\x1b[0m\x1b[2J\x1b[H");
        for (body) |c| {
            if (c == '\n') {
                try self.scratch.appendSlice(self.alloc, "\r\n");
            } else {
                try self.scratch.append(self.alloc, c);
            }
        }
        try self.scratch.appendSlice(self.alloc, "\x1b[0m");
        try self.appendPaneStateRestore(pane_id, screen, &self.scratch);
        self.sink.write(pane_id, self.scratch.items);
    }

    fn applyLayout(self: *Session, window_id: usize, layout_str: []const u8) Allocator.Error!void {
        var tree = layout.parse(self.alloc, layout_str) catch return; // ignore malformed layouts
        defer tree.deinit();
        const w = try self.ensureWindow(window_id);
        w.panes.clearRetainingCapacity();
        try collectPanes(self.alloc, &w.panes, tree.root);
        // `tree` is still alive (its `deinit` runs at scope exit); the bridge
        // consumes `root` synchronously inside this call.
        self.events.onLayoutChange(self.events.ctx, window_id, &tree.root);
    }

    /// Parse a `list-windows` reply body and apply each line as a layout. New
    /// replies are tab-separated:
    ///
    ///     #{window_id}\t#{window_active}\t#{window_layout}\t#{window_name}
    ///
    /// Returns true if at least one line applied — the `block_end` handler uses
    /// that to tell a window-list reply apart from a capture-pane reply.
    /// Non-matching lines are skipped.
    fn applyWindowList(self: *Session, body: []const u8) Allocator.Error!bool {
        var applied = false;
        var active_window: ?usize = null;
        var seen: std.ArrayListUnmanaged(usize) = .empty;
        defer seen.deinit(self.alloc);

        var lines = std.mem.splitScalar(u8, body, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \r\t");
            const parsed = parseWindowListLine(line) orelse continue;
            try seen.append(self.alloc, parsed.id);
            try self.applyLayout(parsed.id, parsed.layout_str);
            const w = self.findWindow(parsed.id) orelse continue;
            w.active = parsed.active;
            if (parsed.name) |name| {
                try self.renameWindow(parsed.id, name);
                self.events.onWindowRenamed(self.events.ctx, parsed.id, name);
            }
            if (parsed.active) active_window = parsed.id;
            applied = true;
        }
        if (applied) self.removeWindowsNotIn(seen.items);
        self.active_window = active_window;
        if (active_window) |id| {
            self.events.onActiveWindowChanged(self.events.ctx, id);
        }
        return applied;
    }

    /// Parse the cwd/current-command metadata query and emit onPaneMeta per
    /// line. Terminal state is intentionally queried separately with a safe
    /// semicolon delimiter: paths may contain spaces, while state has many
    /// optional fields whose empty values must not collapse.
    /// Returns true if at least one line applied. The caller (block_end) gates
    /// this via `isPaneListReply` so it is only reached when the body is
    /// unambiguously a pane-list; per-line parsing is lenient (skips malformed).
    fn applyPaneList(self: *Session, body: []const u8) Allocator.Error!bool {
        var applied = false;
        var lines = std.mem.splitScalar(u8, body, '\n');
        while (lines.next()) |raw| {
            const parsed = parsePaneListLine(raw) orelse continue;
            self.events.onPaneMeta(self.events.ctx, parsed.id, parsed.path, parsed.cmd);
            applied = true;
        }
        return applied;
    }

    const PaneListLine = struct {
        id: usize,
        path: []const u8,
        cmd: []const u8,
    };

    fn parsePaneListLine(raw: []const u8) ?PaneListLine {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (line.len < 2 or line[0] != '%') return null;
        if (std.mem.indexOfScalar(u8, line, '\t') != null) {
            return parseTabbedPaneListLine(line);
        }
        return parseWhitespacePaneListLine(line);
    }

    fn parseTabbedPaneListLine(line: []const u8) ?PaneListLine {
        const t1 = std.mem.indexOfScalar(u8, line, '\t') orelse return null;
        const id = std.fmt.parseInt(usize, line[1..t1], 10) catch return null;
        const rest = line[t1 + 1 ..];
        const t2 = std.mem.indexOfScalar(u8, rest, '\t') orelse return null;
        const path = rest[0..t2];
        const cmd_and_state = rest[t2 + 1 ..];
        const t3 = std.mem.indexOfScalar(u8, cmd_and_state, '\t');
        return .{
            .id = id,
            .path = path,
            .cmd = if (t3) |idx| cmd_and_state[0..idx] else cmd_and_state,
        };
    }

    const TokenRange = struct { start: usize, end: usize };

    fn isPaneFieldSpace(c: u8) bool {
        return c == ' ' or c == '\t' or c == '\r';
    }

    fn lastTokenBefore(s: []const u8, before: usize) ?TokenRange {
        var end = @min(before, s.len);
        while (end > 0 and isPaneFieldSpace(s[end - 1])) end -= 1;
        if (end == 0) return null;
        var begin = end;
        while (begin > 0 and !isPaneFieldSpace(s[begin - 1])) begin -= 1;
        return .{ .start = begin, .end = end };
    }

    fn parseWhitespacePaneListLine(line: []const u8) ?PaneListLine {
        var id_end: usize = 1;
        while (id_end < line.len and !isPaneFieldSpace(line[id_end])) id_end += 1;
        if (id_end == line.len) return null;
        const id = std.fmt.parseInt(usize, line[1..id_end], 10) catch return null;

        const rest = std.mem.trimLeft(u8, line[id_end..], " \r\t");
        const cmd = lastTokenBefore(rest, rest.len) orelse return null;
        const path = std.mem.trim(u8, rest[0..cmd.start], " \r\t");
        if (path.len == 0) return null;

        return .{
            .id = id,
            .path = path,
            .cmd = rest[cmd.start..cmd.end],
        };
    }

    const CursorShape = enum { default, block, underline, bar };

    const ParsedPaneState = struct {
        pane_id: usize,
        cursor_x: ?usize,
        cursor_y: ?usize,
        cursor_visible: ?bool,
        cursor_shape: ?CursorShape,
        cursor_blinking: ?bool,
        alternate_on: bool,
        alternate_saved_x: ?usize,
        alternate_saved_y: ?usize,
        insert: ?bool,
        wrap: ?bool,
        keypad: ?bool,
        cursor_keys: ?bool,
        origin: ?bool,
        mouse_all: ?bool,
        mouse_button: ?bool,
        mouse_standard: ?bool,
        mouse_utf8: ?bool,
        mouse_sgr: ?bool,
        focus: ?bool,
        bracketed_paste: ?bool,
        scroll_top: ?usize,
        scroll_bottom: ?usize,
        pane_tabs: ?[]const u8,
    };

    fn parseOptionalBool(field: ?[]const u8) ?bool {
        const value = std.mem.trim(u8, field orelse return null, " \r\t");
        if (std.mem.eql(u8, value, "1")) return true;
        if (std.mem.eql(u8, value, "0")) return false;
        return null;
    }

    fn parseOptionalInt(field: ?[]const u8) ?usize {
        const value = std.mem.trim(u8, field orelse return null, " \r\t");
        if (value.len == 0) return null;
        return std.fmt.parseInt(usize, value, 10) catch null;
    }

    fn parseCursorShape(field: ?[]const u8) ?CursorShape {
        const value = std.mem.trim(u8, field orelse return null, " \r\t");
        if (std.mem.eql(u8, value, "default")) return .default;
        if (std.mem.eql(u8, value, "block")) return .block;
        if (std.mem.eql(u8, value, "underline")) return .underline;
        if (std.mem.eql(u8, value, "bar")) return .bar;
        return null;
    }

    fn parsePaneStateLine(raw: []const u8) ?ParsedPaneState {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (line.len < 2 or line[0] != '%') return null;

        var fields = std.mem.splitScalar(u8, line, ';');
        const pane = fields.next() orelse return null;
        const pane_id = std.fmt.parseInt(usize, pane[1..], 10) catch return null;
        const cursor_x = parseOptionalInt(fields.next());
        const cursor_y = parseOptionalInt(fields.next());
        const cursor_visible = parseOptionalBool(fields.next());
        const cursor_shape = parseCursorShape(fields.next());
        const cursor_blinking = parseOptionalBool(fields.next());
        const alternate_on = parseOptionalBool(fields.next()) orelse false;
        const alternate_saved_x = parseOptionalInt(fields.next());
        const alternate_saved_y = parseOptionalInt(fields.next());
        const insert = parseOptionalBool(fields.next());
        const wrap = parseOptionalBool(fields.next());
        const keypad = parseOptionalBool(fields.next());
        const cursor_keys = parseOptionalBool(fields.next());
        const origin = parseOptionalBool(fields.next());
        const mouse_all = parseOptionalBool(fields.next());
        _ = parseOptionalBool(fields.next()); // mouse_any_flag is an aggregate.
        const mouse_button = parseOptionalBool(fields.next());
        const mouse_standard = parseOptionalBool(fields.next());
        const mouse_utf8 = parseOptionalBool(fields.next());
        const mouse_sgr = parseOptionalBool(fields.next());
        const focus = parseOptionalBool(fields.next());
        const bracketed_paste = parseOptionalBool(fields.next());
        const scroll_top = parseOptionalInt(fields.next());
        const scroll_bottom = parseOptionalInt(fields.next());
        const pane_tabs = fields.next();

        return .{
            .pane_id = pane_id,
            .cursor_x = cursor_x,
            .cursor_y = cursor_y,
            .cursor_visible = cursor_visible,
            .cursor_shape = cursor_shape,
            .cursor_blinking = cursor_blinking,
            .alternate_on = alternate_on,
            .alternate_saved_x = alternate_saved_x,
            .alternate_saved_y = alternate_saved_y,
            .insert = insert,
            .wrap = wrap,
            .keypad = keypad,
            .cursor_keys = cursor_keys,
            .origin = origin,
            .mouse_all = mouse_all,
            .mouse_button = mouse_button,
            .mouse_standard = mouse_standard,
            .mouse_utf8 = mouse_utf8,
            .mouse_sgr = mouse_sgr,
            .focus = focus,
            .bracketed_paste = bracketed_paste,
            .scroll_top = scroll_top,
            .scroll_bottom = scroll_bottom,
            .pane_tabs = pane_tabs,
        };
    }

    fn appendPrivateMode(self: *Session, out: *std.ArrayListUnmanaged(u8), mode: usize, enabled: bool) Allocator.Error!void {
        var buf: [32]u8 = undefined;
        const seq = std.fmt.bufPrint(&buf, "\x1b[?{d}{c}", .{ mode, @as(u8, if (enabled) 'h' else 'l') }) catch unreachable;
        try out.appendSlice(self.alloc, seq);
    }

    fn appendCursorPosition(
        self: *Session,
        out: *std.ArrayListUnmanaged(u8),
        x: usize,
        y: usize,
    ) Allocator.Error!void {
        var buf: [48]u8 = undefined;
        const seq = std.fmt.bufPrint(&buf, "\x1b[{d};{d}H", .{ y + 1, x + 1 }) catch unreachable;
        try out.appendSlice(self.alloc, seq);
    }

    fn buildPaneRestore(self: *Session, parsed: ParsedPaneState, out: *std.ArrayListUnmanaged(u8)) Allocator.Error!void {
        if (parsed.insert) |enabled| try out.appendSlice(self.alloc, if (enabled) "\x1b[4h" else "\x1b[4l");
        if (parsed.wrap) |enabled| try self.appendPrivateMode(out, 7, enabled);
        if (parsed.keypad) |enabled| try out.appendSlice(self.alloc, if (enabled) "\x1b=" else "\x1b>");
        if (parsed.cursor_keys) |enabled| try self.appendPrivateMode(out, 1, enabled);

        if (parsed.mouse_all != null or parsed.mouse_button != null or parsed.mouse_standard != null) {
            try out.appendSlice(self.alloc, "\x1b[?1000l\x1b[?1002l\x1b[?1003l");
            if (parsed.mouse_all == true) {
                try out.appendSlice(self.alloc, "\x1b[?1003h");
            } else if (parsed.mouse_button == true) {
                try out.appendSlice(self.alloc, "\x1b[?1002h");
            } else if (parsed.mouse_standard == true) {
                try out.appendSlice(self.alloc, "\x1b[?1000h");
            }
        }
        if (parsed.mouse_utf8 != null or parsed.mouse_sgr != null) {
            try out.appendSlice(self.alloc, "\x1b[?1005l\x1b[?1006l");
            if (parsed.mouse_sgr == true) {
                try out.appendSlice(self.alloc, "\x1b[?1006h");
            } else if (parsed.mouse_utf8 == true) {
                try out.appendSlice(self.alloc, "\x1b[?1005h");
            }
        }
        if (parsed.focus) |enabled| try self.appendPrivateMode(out, 1004, enabled);
        if (parsed.bracketed_paste) |enabled| try self.appendPrivateMode(out, 2004, enabled);

        if (parsed.scroll_top) |top| {
            if (parsed.scroll_bottom) |bottom| {
                var buf: [48]u8 = undefined;
                const seq = std.fmt.bufPrint(&buf, "\x1b[{d};{d}r", .{ top + 1, bottom + 1 }) catch unreachable;
                try out.appendSlice(self.alloc, seq);
            }
        }

        if (parsed.pane_tabs) |tabs| {
            try out.appendSlice(self.alloc, "\x1b[3g");
            var it = std.mem.splitScalar(u8, tabs, ',');
            while (it.next()) |field| {
                const col = parseOptionalInt(field) orelse continue;
                var buf: [32]u8 = undefined;
                const seq = std.fmt.bufPrint(&buf, "\x1b[{d}G\x1bH", .{col + 1}) catch unreachable;
                try out.appendSlice(self.alloc, seq);
            }
        }

        if (parsed.origin) |enabled| try self.appendPrivateMode(out, 6, enabled);
        if (parsed.cursor_shape) |shape| {
            const style: ?u8 = switch (shape) {
                .default => null,
                .block => if (parsed.cursor_blinking orelse true) 1 else 2,
                .underline => if (parsed.cursor_blinking orelse true) 3 else 4,
                .bar => if (parsed.cursor_blinking orelse true) 5 else 6,
            };
            if (style) |value| {
                var buf: [16]u8 = undefined;
                const seq = std.fmt.bufPrint(&buf, "\x1b[{d} q", .{value}) catch unreachable;
                try out.appendSlice(self.alloc, seq);
            }
        }
        if (parsed.cursor_blinking) |enabled| try self.appendPrivateMode(out, 12, enabled);
        if (parsed.cursor_x) |x| {
            if (parsed.cursor_y) |absolute_y| {
                const y = if (parsed.origin == true and parsed.scroll_top != null and absolute_y >= parsed.scroll_top.?)
                    absolute_y - parsed.scroll_top.?
                else
                    absolute_y;
                try self.appendCursorPosition(out, x, y);
            }
        }
        if (parsed.cursor_visible) |enabled| try self.appendPrivateMode(out, 25, enabled);
    }

    fn setPaneState(self: *Session, parsed: ParsedPaneState) Allocator.Error!void {
        var stored = PaneState{
            .pane_id = parsed.pane_id,
            .alternate_on = parsed.alternate_on,
            .alternate_saved_x = parsed.alternate_saved_x,
            .alternate_saved_y = parsed.alternate_saved_y,
        };
        errdefer stored.deinit(self.alloc);
        try self.buildPaneRestore(parsed, &stored.restore);

        for (self.pane_states.items) |*existing| {
            if (existing.pane_id == parsed.pane_id) {
                existing.deinit(self.alloc);
                existing.* = stored;
                return;
            }
        }
        try self.pane_states.append(self.alloc, stored);
    }

    fn clearPaneStates(self: *Session) void {
        for (self.pane_states.items) |*state| state.deinit(self.alloc);
        self.pane_states.clearRetainingCapacity();
    }

    fn removePendingPaneState(self: *Session, pane_id: usize) void {
        for (self.pane_states.items, 0..) |*state, i| {
            if (state.pane_id != pane_id or !state.pending) continue;
            state.deinit(self.alloc);
            _ = self.pane_states.orderedRemove(i);
            return;
        }
    }

    fn findPaneStateMutable(self: *Session, pane_id: usize) ?*PaneState {
        for (self.pane_states.items) |*state| {
            if (state.pane_id == pane_id) return state;
        }
        return null;
    }

    fn findPaneState(self: *const Session, pane_id: usize) ?*const PaneState {
        for (self.pane_states.items) |*state| {
            if (state.pane_id == pane_id) return state;
        }
        return null;
    }

    fn activeCaptureScreen(state: *const PaneState) CaptureScreen {
        return if (state.alternate_on) .alternate else .primary;
    }

    fn appendPaneStateRestore(
        self: *Session,
        pane_id: usize,
        screen: CaptureScreen,
        out: *std.ArrayListUnmanaged(u8),
    ) Allocator.Error!void {
        const state = self.findPaneState(pane_id) orelse return;
        if (screen == activeCaptureScreen(state)) {
            try out.appendSlice(self.alloc, state.restore.items);
            return;
        }

        // With alternate_on=1, tmux's `capture-pane -a` returns the saved
        // primary grid. Position its cursor before the following ?1049h so
        // ghostty-vt saves the same primary cursor that tmux will restore when
        // the TUI exits.
        if (screen == .primary and state.alternate_on) {
            if (state.alternate_saved_x) |x| {
                if (state.alternate_saved_y) |y| {
                    if (std.math.cast(u16, x) != null and std.math.cast(u16, y) != null)
                        try self.appendCursorPosition(out, x, y);
                }
            }
        }
    }

    fn applyPaneState(self: *Session, body: []const u8, req: PaneStateRequest) Allocator.Error!bool {
        var applied = false;
        var lines = std.mem.splitScalar(u8, body, '\n');
        while (lines.next()) |raw| {
            const parsed = parsePaneStateLine(raw) orelse continue;
            try self.setPaneState(parsed);
            if (req.capture) try self.captureInitialPane(parsed.pane_id, parsed.alternate_on);
            applied = true;
        }
        if (req.pane_id) |pane_id| self.removePendingPaneState(pane_id);
        return applied;
    }

    fn removeWindowsNotIn(self: *Session, ids: []const usize) void {
        var i: usize = 0;
        while (i < self.windows.items.len) {
            const id = self.windows.items[i].id;
            if (containsId(ids, id)) {
                i += 1;
                continue;
            }
            self.events.onWindowClose(self.events.ctx, id);
            self.windows.items[i].deinit(self.alloc);
            _ = self.windows.orderedRemove(i);
            if (self.active_window == id) self.active_window = null;
        }
    }

    /// Queue the screen captures only after pane state is known. tmux's default
    /// capture is the active grid; `-a` is the saved/inactive grid. Therefore an
    /// active TUI must restore saved primary first, then current alternate.
    fn captureInitialPane(self: *Session, pane_id: usize, alternate_on: bool) Allocator.Error!void {
        if (alternate_on) {
            try self.capturePaneScreen(pane_id, .primary, true);
            try self.capturePaneScreen(pane_id, .alternate, false);
        } else {
            try self.capturePaneScreen(pane_id, .primary, false);
        }
    }

    /// `saved_grid` selects tmux's `capture-pane -a`; `screen` is the semantic
    /// WispTerm target that receives the reply.
    fn capturePaneScreen(self: *Session, pane_id: usize, screen: CaptureScreen, saved_grid: bool) Allocator.Error!void {
        var buf: [64]u8 = undefined;
        const s = if (saved_grid)
            std.fmt.bufPrint(&buf, "capture-pane -p -e -q -a -t %{d}\n", .{pane_id}) catch unreachable
        else
            std.fmt.bufPrint(&buf, "capture-pane -p -e -q -t %{d}\n", .{pane_id}) catch unreachable;
        try self.enqueueCommand(s, .{ .capture = .{ .pane_id = pane_id, .screen = screen } });
    }

    /// Use only printable delimiters in commands sent through the outer SSH
    /// tty. tmux sanitizes literal control characters in control-mode command
    /// arguments (a tab becomes `_`), which makes the reply impossible to
    /// parse. The pane parser takes the last whitespace token as the command,
    /// so paths containing spaces remain valid.
    const list_panes_cmd = "list-panes -s -F \"#{pane_id} #{pane_current_path} #{pane_current_command}\"\n";
    const list_windows_cmd = "list-windows -F \"#{window_id} #{window_active} #{window_layout} #{window_name}\"\n";
    // Mirrors Ghostty's tmux Viewer pane-state query. Semicolons preserve empty
    // fields on older tmux versions that do not expose every newer variable.
    const pane_state_format =
        "#{pane_id};#{cursor_x};#{cursor_y};#{cursor_flag};#{cursor_shape};#{cursor_blinking};" ++
        "#{alternate_on};#{alternate_saved_x};#{alternate_saved_y};#{insert_flag};#{wrap_flag};#{keypad_flag};" ++
        "#{keypad_cursor_flag};#{origin_flag};#{mouse_all_flag};#{mouse_any_flag};#{mouse_button_flag};" ++
        "#{mouse_standard_flag};#{mouse_utf8_flag};#{mouse_sgr_flag};#{focus_flag};#{bracketed_paste};" ++
        "#{scroll_region_upper};#{scroll_region_lower};#{pane_tabs}";

    /// Enqueue the attach bootstrap: tell tmux our client size and ask for the
    /// window list. (Parsing the list-windows reply for complete initial
    /// enumeration is Phase 3; the live model is built from pushed
    /// notifications.)
    pub fn start(self: *Session) Allocator.Error!void {
        try self.enqueueResize();
        try self.enqueueCommand(list_windows_cmd, .window_list);
        try self.enqueueCommand(list_panes_cmd, .pane_list);
    }

    /// Ensure a pane Surface is seeded from tmux. Existing reconciled panes are
    /// skipped during ordinary layout changes; a newly created Surface asks for
    /// fresh state even if this pane id was seen before (for example after its
    /// local tab was closed). Reconnect clears the cache, so reused Surfaces are
    /// queried and seeded again as well.
    pub fn requestPaneSeed(self: *Session, pane_id: usize, refresh: bool) Allocator.Error!void {
        if (self.findPaneStateMutable(pane_id)) |state| {
            if (state.pending or !refresh) return;
            state.pending = true;
        } else {
            try self.pane_states.append(self.alloc, .{ .pane_id = pane_id, .pending = true });
        }
        errdefer self.removePendingPaneState(pane_id);

        const command = try std.fmt.allocPrint(
            self.alloc,
            "display-message -p -t %{d} -F \"{s}\"\n",
            .{ pane_id, pane_state_format },
        );
        defer self.alloc.free(command);
        try self.enqueueCommand(command, .{ .pane_state = .{ .capture = true, .pane_id = pane_id } });
    }

    /// Re-query per-pane metadata (cwd + current command). Called periodically
    /// by the controller; cwd/command change infrequently so a coarse cadence
    /// is fine.
    pub fn refreshPaneMeta(self: *Session) Allocator.Error!void {
        try self.enqueueCommand(list_panes_cmd, .pane_list);
    }

    pub fn resizeClient(self: *Session, cols: u16, rows: u16) Allocator.Error!void {
        self.cols = cols;
        self.rows = rows;
        try self.enqueueResize();
    }

    fn enqueueResize(self: *Session) Allocator.Error!void {
        var buf: [64]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "refresh-client -C {d}x{d}\n", .{ self.cols, self.rows }) catch unreachable;
        try self.enqueueCommand(s, .ignore);
    }

    /// Queue terminal input using tmux's long-standing hexadecimal key-name
    /// syntax. `send-keys -H` is newer than tmux 2.7, which is still common on
    /// long-lived servers; `0x<codepoint>` works there and on current tmux.
    /// Decode valid UTF-8 so non-ASCII text is not encoded a second time by
    /// tmux, while ASCII control/mouse bytes remain exact codepoints.
    pub fn sendKeys(self: *Session, pane_id: usize, raw: []const u8) Allocator.Error!void {
        const old_len = self.cmds.items.len;
        errdefer self.cmds.items.len = old_len;

        var head: [48]u8 = undefined;
        const h = std.fmt.bufPrint(&head, "send-keys -t %{d}", .{pane_id}) catch unreachable;
        try self.cmds.appendSlice(self.alloc, h);

        var i: usize = 0;
        while (i < raw.len) {
            const seq_len = std.unicode.utf8ByteSequenceLength(raw[i]) catch 1;
            const end = @min(raw.len, i + seq_len);
            var codepoint: u21 = raw[i];
            var advance: usize = 1;
            if (seq_len > 1 and end - i == seq_len) {
                const decoded: ?u21 = std.unicode.utf8Decode(raw[i..end]) catch null;
                if (decoded) |cp| {
                    codepoint = cp;
                    advance = seq_len;
                }
            }
            var hb: [16]u8 = undefined;
            const hs = std.fmt.bufPrint(&hb, " 0x{x}", .{codepoint}) catch unreachable;
            try self.cmds.appendSlice(self.alloc, hs);
            i += advance;
        }
        try self.cmds.append(self.alloc, '\n');
        try self.reply_queue.append(self.alloc, .ignore);
    }

    pub fn splitPane(self: *Session, pane_id: usize, dir: layout.Dir) Allocator.Error!void {
        const flag = switch (dir) {
            .horizontal => "-h",
            .vertical => "-v",
        };
        var buf: [48]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "split-window {s} -t %{d}\n", .{ flag, pane_id }) catch unreachable;
        try self.enqueueCommand(s, .ignore);
    }

    pub fn newWindow(self: *Session) Allocator.Error!void {
        try self.enqueueCommand("new-window\n", .ignore);
    }

    pub fn killWindow(self: *Session, id: usize) Allocator.Error!void {
        var buf: [48]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "kill-window -t @{d}\n", .{id}) catch unreachable;
        try self.enqueueCommand(s, .ignore);
    }

    pub fn killPane(self: *Session, pane_id: usize) Allocator.Error!void {
        var buf: [48]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "kill-pane -t %{d}\n", .{pane_id}) catch unreachable;
        try self.enqueueCommand(s, .ignore);
    }
};

const WindowListLine = struct {
    id: usize,
    active: bool = false,
    layout_str: []const u8,
    name: ?[]const u8 = null,
};

fn parseWindowListLine(line: []const u8) ?WindowListLine {
    if (line.len < 2 or line[0] != '@') return null;
    if (std.mem.indexOfScalar(u8, line, '\t') != null) return parseTabbedWindowListLine(line);
    return parseWhitespaceWindowListLine(line);
}

fn isWindowListReply(body: []const u8) bool {
    var found_any = false;
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (line.len == 0) continue;
        if (parseWindowListLine(line) == null) return false;
        found_any = true;
    }
    return found_any;
}

fn parseTabbedWindowListLine(line: []const u8) ?WindowListLine {
    const tab1 = std.mem.indexOfScalar(u8, line, '\t') orelse return null;
    const id = std.fmt.parseInt(usize, line[1..tab1], 10) catch return null;
    const rest1 = line[tab1 + 1 ..];
    const tab2 = std.mem.indexOfScalar(u8, rest1, '\t') orelse return null;
    const active = std.mem.eql(u8, rest1[0..tab2], "1");
    const rest2 = rest1[tab2 + 1 ..];
    const tab3 = std.mem.indexOfScalar(u8, rest2, '\t');
    const layout_str = if (tab3) |idx| rest2[0..idx] else rest2;
    if (layout_str.len == 0) return null;
    return .{
        .id = id,
        .active = active,
        .layout_str = layout_str,
        .name = if (tab3) |idx| rest2[idx + 1 ..] else null,
    };
}

fn parseWhitespaceWindowListLine(line: []const u8) ?WindowListLine {
    const sp1 = std.mem.indexOfScalar(u8, line, ' ') orelse return null;
    const id = std.fmt.parseInt(usize, line[1..sp1], 10) catch return null;

    const rest1 = std.mem.trimLeft(u8, line[sp1 + 1 ..], " ");
    const sp2 = std.mem.indexOfScalar(u8, rest1, ' ') orelse return null;
    const active = std.mem.eql(u8, rest1[0..sp2], "1");

    const rest2 = std.mem.trimLeft(u8, rest1[sp2 + 1 ..], " ");
    const sp3 = std.mem.indexOfScalar(u8, rest2, ' ');
    const layout_str = if (sp3) |idx| rest2[0..idx] else rest2;
    if (layout_str.len == 0) return null;
    return .{
        .id = id,
        .active = active,
        .layout_str = layout_str,
        .name = if (sp3) |idx| std.mem.trimLeft(u8, rest2[idx + 1 ..], " ") else null,
    };
}

/// Returns true iff `body` is a `list-panes` reply: there is at least one
/// non-empty line AND every non-empty line can be parsed as pane metadata.
/// Blank/whitespace-only lines are ignored. This strict check lets block_end
/// distinguish a pane-list reply from real capture scrollback (which won't have
/// ALL lines in that shape).
fn isPaneListReply(body: []const u8) bool {
    var found_any = false;
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (line.len == 0) continue;
        if (Session.parsePaneListLine(line) == null and !hasPaneListPrefix(line)) return false;
        found_any = true;
    }
    return found_any;
}

fn hasPaneListPrefix(line: []const u8) bool {
    if (line.len < 3 or line[0] != '%') return false;
    var i: usize = 1;
    while (i < line.len and std.ascii.isDigit(line[i])) i += 1;
    return i > 1 and i < line.len and Session.isPaneFieldSpace(line[i]);
}

/// True if a `%error` reply body says the attach target no longer exists: the
/// session was killed, or the last one exited and the server quit. These are
/// tmux's own English (non-localized) messages. Used to tell a reconnect that
/// found a dead session (close) from one that re-attached a live one (continue).
pub fn isSessionGoneError(body: []const u8) bool {
    return std.mem.indexOf(u8, body, "can't find session") != null or
        std.mem.indexOf(u8, body, "no sessions") != null or
        std.mem.indexOf(u8, body, "no server running") != null or
        std.mem.indexOf(u8, body, "no current session") != null;
}

fn containsId(ids: []const usize, id: usize) bool {
    for (ids) |candidate| {
        if (candidate == id) return true;
    }
    return false;
}

fn collectPanes(
    alloc: Allocator,
    out: *std.ArrayListUnmanaged(usize),
    node: layout.Node,
) Allocator.Error!void {
    switch (node) {
        .leaf => |l| try out.append(alloc, l.pane_id),
        .split => |s| {
            for (s.children) |child| try collectPanes(alloc, out, child);
        },
    }
}

// ----- tests -----

const Collector = struct {
    alloc: Allocator,
    last_pane: usize = 0,
    buf: std.ArrayListUnmanaged(u8) = .empty,

    fn sink(self: *Collector) PaneSink {
        return .{ .ctx = self, .writeFn = writeImpl };
    }

    fn writeImpl(ctx: *anyopaque, pane_id: usize, bytes: []const u8) void {
        const self: *Collector = @ptrCast(@alignCast(ctx));
        self.last_pane = pane_id;
        self.buf.appendSlice(self.alloc, bytes) catch {};
    }

    fn deinit(self: *Collector) void {
        self.buf.deinit(self.alloc);
    }
};

test "session initializes empty" {
    var col = Collector{ .alloc = std.testing.allocator };
    defer col.deinit();
    var s = Session.init(std.testing.allocator, col.sink(), 80, 24);
    defer s.deinit();
    try std.testing.expectEqual(@as(usize, 0), s.windowCount());
    try std.testing.expectEqual(@as(usize, 0), s.pendingCommands().len);
}

test "feed routes unescaped %output to the sink for the right pane" {
    var col = Collector{ .alloc = std.testing.allocator };
    defer col.deinit();
    var s = Session.init(std.testing.allocator, col.sink(), 80, 24);
    defer s.deinit();

    // \033 octal-escapes to ESC (0x1b).
    try s.feed("%output %7 ab\\033c\n");
    try std.testing.expectEqual(@as(usize, 7), col.last_pane);
    try std.testing.expectEqualSlices(u8, &.{ 'a', 'b', 0x1b, 'c' }, col.buf.items);
}

test "window-add/renamed/close maintain the window list" {
    var col = Collector{ .alloc = std.testing.allocator };
    defer col.deinit();
    var s = Session.init(std.testing.allocator, col.sink(), 80, 24);
    defer s.deinit();

    try s.feed("%window-add @3\n");
    try s.feed("%window-add @5\n");
    try std.testing.expectEqual(@as(usize, 2), s.windowCount());

    try s.feed("%window-renamed @3 build\n");
    try std.testing.expectEqualStrings("build", s.findWindow(3).?.name.items);

    try s.feed("%window-close @3\n");
    try std.testing.expectEqual(@as(usize, 1), s.windowCount());
    try std.testing.expect(s.findWindow(3) == null);
}

test "window-pane-changed sets the active pane" {
    var col = Collector{ .alloc = std.testing.allocator };
    defer col.deinit();
    var s = Session.init(std.testing.allocator, col.sink(), 80, 24);
    defer s.deinit();

    try s.feed("%window-pane-changed @1 %9\n");
    try std.testing.expectEqual(@as(?usize, 9), s.active_pane);
}

test "layout-change populates a window's pane list in layout order" {
    var col = Collector{ .alloc = std.testing.allocator };
    defer col.deinit();
    var s = Session.init(std.testing.allocator, col.sink(), 80, 24);
    defer s.deinit();

    try s.feed("%layout-change @1 bd1b,80x24,0,0{40x24,0,0,1,39x24,41,0,2} bd1b,80x24,0,0{40x24,0,0,1,39x24,41,0,2} *\n");
    const panes = s.findWindow(1).?.panes.items;
    try std.testing.expectEqualSlices(usize, &.{ 1, 2 }, panes);
}

test "start enqueues the attach bootstrap commands" {
    var col = Collector{ .alloc = std.testing.allocator };
    defer col.deinit();
    var s = Session.init(std.testing.allocator, col.sink(), 120, 40);
    defer s.deinit();

    try s.start();
    const cmds = s.pendingCommands();
    try std.testing.expect(std.mem.indexOf(u8, cmds, "refresh-client -C 120x40\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, cmds, "list-windows") != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, cmds, '\t') == null);
}

test "SSH tty bootstrap replies keep printable separators and reconcile" {
    var col = Collector{ .alloc = std.testing.allocator };
    defer col.deinit();
    var log = EventLog{ .alloc = std.testing.allocator };
    defer log.deinit();
    var s = Session.init(std.testing.allocator, col.sink(), 80, 24);
    defer s.deinit();
    s.events = log.eventSink();

    try s.start();
    try std.testing.expect(std.mem.indexOfScalar(u8, s.pendingCommands(), '\t') == null);

    // A real `ssh -tt ... tmux -CC` attach first completes its own empty
    // command block, then replies to the printable-space bootstrap queries.
    try s.feed("\x1bP1000p%begin 1 1 0\n%end 1 1 0\n%session-changed $0 tui\n");
    try s.feed("%begin 2 2 0\n@5 1 b262,80x24,0,0,5 TUI window\n%end 2 2 0\n");
    try s.feed("%begin 3 3 0\n%5 /home/xzg/project with spaces pi\n%end 3 3 0\n");

    try std.testing.expectEqual(@as(?usize, 5), log.layout_window);
    try std.testing.expectEqual(@as(usize, 1), log.layout_panes);
    try std.testing.expectEqualStrings("TUI window", s.findWindow(5).?.name.items);
    try std.testing.expectEqual(@as(?usize, 5), log.last_pane_meta_id);
    try std.testing.expectEqualStrings("/home/xzg/project with spaces", log.last_pane_meta_path.items);
    try std.testing.expectEqualStrings("pi", log.last_pane_meta_cmd.items);
}

test "resizeClient updates size and queues a refresh" {
    var col = Collector{ .alloc = std.testing.allocator };
    defer col.deinit();
    var s = Session.init(std.testing.allocator, col.sink(), 80, 24);
    defer s.deinit();

    try s.resizeClient(100, 30);
    try std.testing.expectEqual(@as(u16, 100), s.cols);
    try std.testing.expect(std.mem.indexOf(u8, s.pendingCommands(), "refresh-client -C 100x30\n") != null);
}

test "sendKeys uses tmux 2.7-compatible hexadecimal key names" {
    var col = Collector{ .alloc = std.testing.allocator };
    defer col.deinit();
    var s = Session.init(std.testing.allocator, col.sink(), 80, 24);
    defer s.deinit();

    try s.sendKeys(4, "ls\n");
    try std.testing.expectEqualStrings("send-keys -t %4 0x6c 0x73 0xa\n", s.pendingCommands());
}

test "sendKeys emits UTF-8 text as Unicode key names" {
    var col = Collector{ .alloc = std.testing.allocator };
    defer col.deinit();
    var s = Session.init(std.testing.allocator, col.sink(), 80, 24);
    defer s.deinit();

    try s.sendKeys(4, "Ãé中");
    try std.testing.expectEqualStrings("send-keys -t %4 0xc3 0xe9 0x4e2d\n", s.pendingCommands());
}

test "sendKeys preserves legacy mouse report bytes on tmux 2.7" {
    var col = Collector{ .alloc = std.testing.allocator };
    defer col.deinit();
    var s = Session.init(std.testing.allocator, col.sink(), 80, 24);
    defer s.deinit();

    try s.sendKeys(5, "\x1b[MaC-");
    try std.testing.expectEqualStrings(
        "send-keys -t %5 0x1b 0x5b 0x4d 0x61 0x43 0x2d\n",
        s.pendingCommands(),
    );
}

test "splitPane emits split-window with the right orientation flag" {
    var col = Collector{ .alloc = std.testing.allocator };
    defer col.deinit();
    var s = Session.init(std.testing.allocator, col.sink(), 80, 24);
    defer s.deinit();

    try s.splitPane(2, .horizontal);
    try std.testing.expectEqualStrings("split-window -h -t %2\n", s.pendingCommands());
    s.clearCommands();
    try s.splitPane(2, .vertical);
    try std.testing.expectEqualStrings("split-window -v -t %2\n", s.pendingCommands());
}

test "newWindow and killWindow emit their commands" {
    var col = Collector{ .alloc = std.testing.allocator };
    defer col.deinit();
    var s = Session.init(std.testing.allocator, col.sink(), 80, 24);
    defer s.deinit();

    try s.newWindow();
    try std.testing.expectEqualStrings("new-window\n", s.pendingCommands());
    s.clearCommands();
    try s.killWindow(6);
    try std.testing.expectEqualStrings("kill-window -t @6\n", s.pendingCommands());
}

test "a realistic notification stream builds the full model" {
    var col = Collector{ .alloc = std.testing.allocator };
    defer col.deinit();
    var s = Session.init(std.testing.allocator, col.sink(), 80, 24);
    defer s.deinit();

    // Attach: one window, a single pane, then it splits into two, output flows,
    // focus moves, and finally tmux exits.
    try s.feed("%window-add @0\n");
    try s.feed("%window-renamed @0 main\n");
    try s.feed("%layout-change @0 bd1b,80x24,0,0,1 bd1b,80x24,0,0,1 *\n");
    try s.feed("%layout-change @0 e2f1,80x24,0,0{40x24,0,0,1,39x24,41,0,2} e2f1,80x24,0,0{40x24,0,0,1,39x24,41,0,2} *\n");
    try s.feed("%window-pane-changed @0 %2\n");
    try s.feed("%output %2 done\n");
    try s.feed("%exit\n");

    try std.testing.expectEqual(@as(usize, 1), s.windowCount());
    const w = s.findWindow(0).?;
    try std.testing.expectEqualStrings("main", w.name.items);
    try std.testing.expectEqualSlices(usize, &.{ 1, 2 }, w.panes.items);
    try std.testing.expectEqual(@as(?usize, 2), s.active_pane);
    try std.testing.expectEqual(@as(usize, 2), col.last_pane);
    try std.testing.expectEqualSlices(u8, "done", col.buf.items);
    try std.testing.expect(s.exited);
}

test "a failed reconnect attach flags session_gone, not just exited" {
    var col = Collector{ .alloc = std.testing.allocator };
    defer col.deinit();
    var s = Session.init(std.testing.allocator, col.sink(), 80, 24);
    defer s.deinit();

    // What `tmux -CC attach -t <gone>` actually replies (control-mode enter DCS
    // glued onto %begin, a %error block naming the failure, then %exit).
    try s.feed("\x1bP1000p%begin 1 1 0\r\ncan't find session: wispterm-ngs00\r\n%error 1 1 0\r\n%exit\r\n");
    try std.testing.expect(s.session_gone);
    try std.testing.expect(s.exited);

    // A bare %exit (survivable transport drop) is NOT a gone session.
    var s2 = Session.init(std.testing.allocator, col.sink(), 80, 24);
    defer s2.deinit();
    try s2.feed("%exit\n");
    try std.testing.expect(s2.exited);
    try std.testing.expect(!s2.session_gone);

    // The "no sessions" variant (server quit) also counts as gone.
    try std.testing.expect(isSessionGoneError("no sessions"));
    try std.testing.expect(!isSessionGoneError("boom: a normal command error"));
}

const EventLog = struct {
    alloc: Allocator,
    layout_window: ?usize = null,
    layout_panes: usize = 0,
    renamed_window: ?usize = null,
    renamed_name: std.ArrayListUnmanaged(u8) = .empty,
    closed_window: ?usize = null,
    active_window: ?usize = null,
    active_pane: ?usize = null,
    pane_meta_count: usize = 0,
    last_pane_meta_id: ?usize = null,
    last_pane_meta_path: std.ArrayListUnmanaged(u8) = .empty,
    last_pane_meta_cmd: std.ArrayListUnmanaged(u8) = .empty,

    fn eventSink(self: *EventLog) Session.EventSink {
        return .{
            .ctx = self,
            .onLayoutChange = onLayout,
            .onWindowRenamed = onRenamed,
            .onWindowClose = onClose,
            .onActiveWindowChanged = onActiveWindow,
            .onActivePaneChanged = onActive,
            .onPaneMeta = onPaneMeta,
        };
    }

    fn onLayout(ctx: *anyopaque, window_id: usize, root: *const layout.Node) void {
        const self: *EventLog = @ptrCast(@alignCast(ctx));
        self.layout_window = window_id;
        var n: usize = 0;
        countLeaves(root, &n);
        self.layout_panes = n;
    }
    fn onRenamed(ctx: *anyopaque, window_id: usize, name: []const u8) void {
        const self: *EventLog = @ptrCast(@alignCast(ctx));
        self.renamed_window = window_id;
        self.renamed_name.clearRetainingCapacity();
        self.renamed_name.appendSlice(self.alloc, name) catch {};
    }
    fn onClose(ctx: *anyopaque, window_id: usize) void {
        const self: *EventLog = @ptrCast(@alignCast(ctx));
        self.closed_window = window_id;
    }
    fn onActiveWindow(ctx: *anyopaque, window_id: usize) void {
        const self: *EventLog = @ptrCast(@alignCast(ctx));
        self.active_window = window_id;
    }
    fn onActive(ctx: *anyopaque, pane_id: usize) void {
        const self: *EventLog = @ptrCast(@alignCast(ctx));
        self.active_pane = pane_id;
    }
    fn countLeaves(node: *const layout.Node, out: *usize) void {
        switch (node.*) {
            .leaf => out.* += 1,
            .split => |s| for (s.children) |*c| countLeaves(c, out),
        }
    }
    fn onPaneMeta(ctx: *anyopaque, pane_id: usize, path: []const u8, cmd: []const u8) void {
        const self: *EventLog = @ptrCast(@alignCast(ctx));
        self.pane_meta_count += 1;
        self.last_pane_meta_id = pane_id;
        self.last_pane_meta_path.clearRetainingCapacity();
        self.last_pane_meta_path.appendSlice(self.alloc, path) catch {};
        self.last_pane_meta_cmd.clearRetainingCapacity();
        self.last_pane_meta_cmd.appendSlice(self.alloc, cmd) catch {};
    }

    fn deinit(self: *EventLog) void {
        self.renamed_name.deinit(self.alloc);
        self.last_pane_meta_path.deinit(self.alloc);
        self.last_pane_meta_cmd.deinit(self.alloc);
    }
};

test "EventSink fires onLayoutChange with the parsed root" {
    var col = Collector{ .alloc = std.testing.allocator };
    defer col.deinit();
    var log = EventLog{ .alloc = std.testing.allocator };
    defer log.deinit();
    var s = Session.init(std.testing.allocator, col.sink(), 80, 24);
    defer s.deinit();
    s.events = log.eventSink();

    try s.feed("%layout-change @4 bd1b,80x24,0,0{40x24,0,0,1,39x24,41,0,2} bd1b,80x24,0,0{40x24,0,0,1,39x24,41,0,2} *\n");
    try std.testing.expectEqual(@as(?usize, 4), log.layout_window);
    try std.testing.expectEqual(@as(usize, 2), log.layout_panes);
}

test "EventSink fires onWindowRenamed with the name" {
    var col = Collector{ .alloc = std.testing.allocator };
    defer col.deinit();
    var log = EventLog{ .alloc = std.testing.allocator };
    defer log.deinit();
    var s = Session.init(std.testing.allocator, col.sink(), 80, 24);
    defer s.deinit();
    s.events = log.eventSink();

    try s.feed("%window-renamed @7 build\n");
    try std.testing.expectEqual(@as(?usize, 7), log.renamed_window);
    try std.testing.expectEqualStrings("build", log.renamed_name.items);
}

test "EventSink fires onWindowClose before the window is dropped" {
    var col = Collector{ .alloc = std.testing.allocator };
    defer col.deinit();
    var log = EventLog{ .alloc = std.testing.allocator };
    defer log.deinit();
    var s = Session.init(std.testing.allocator, col.sink(), 80, 24);
    defer s.deinit();
    s.events = log.eventSink();

    try s.feed("%window-add @3\n");
    try s.feed("%window-close @3\n");
    try std.testing.expectEqual(@as(?usize, 3), log.closed_window);
    try std.testing.expect(s.findWindow(3) == null);
}

test "EventSink fires onActivePaneChanged" {
    var col = Collector{ .alloc = std.testing.allocator };
    defer col.deinit();
    var log = EventLog{ .alloc = std.testing.allocator };
    defer log.deinit();
    var s = Session.init(std.testing.allocator, col.sink(), 80, 24);
    defer s.deinit();
    s.events = log.eventSink();

    try s.feed("%window-pane-changed @1 %9\n");
    try std.testing.expectEqual(@as(?usize, 9), log.active_pane);
}

test "block_end list-windows reply drives onLayoutChange per window (bootstrap)" {
    var col = Collector{ .alloc = std.testing.allocator };
    defer col.deinit();
    var log = EventLog{ .alloc = std.testing.allocator };
    defer log.deinit();
    var s = Session.init(std.testing.allocator, col.sink(), 80, 24);
    defer s.deinit();
    s.events = log.eventSink();

    // The reply tmux sends on attach to `list-windows -F "#{window_id}\t#{window_active}\t#{window_layout}\t#{window_name}"`.
    try s.feed("%begin 1 1 0\n@1\t1\tb25e,80x24,0,0,1\tshell\n%end 1 1 0\n");
    try std.testing.expectEqual(@as(?usize, 1), log.layout_window);
    try std.testing.expectEqual(@as(usize, 1), log.layout_panes);
    try std.testing.expectEqual(@as(usize, 1), s.windowCount());
    try std.testing.expectEqualStrings("shell", s.findWindow(1).?.name.items);

    // A non-window-list reply body must not create windows.
    try s.feed("%begin 2 2 0\nsome other output\n%end 2 2 0\n");
    try std.testing.expectEqual(@as(usize, 1), s.windowCount());
}

test "block_end list-windows reply carries window names and the active window" {
    var col = Collector{ .alloc = std.testing.allocator };
    defer col.deinit();
    var log = EventLog{ .alloc = std.testing.allocator };
    defer log.deinit();
    var s = Session.init(std.testing.allocator, col.sink(), 80, 24);
    defer s.deinit();
    s.events = log.eventSink();

    try s.feed(
        "%begin 1 1 0\n" ++
            "@1\t0\tb25e,80x24,0,0,1\tbuild\n" ++
            "@2\t1\tb25e,80x24,0,0,2\teditor tab\n" ++
            "%end 1 1 0\n",
    );

    try std.testing.expectEqual(@as(usize, 2), s.windowCount());
    try std.testing.expectEqualStrings("build", s.findWindow(1).?.name.items);
    try std.testing.expectEqualStrings("editor tab", s.findWindow(2).?.name.items);
    try std.testing.expect(!s.findWindow(1).?.active);
    try std.testing.expect(s.findWindow(2).?.active);
    try std.testing.expectEqual(@as(?usize, 2), s.active_window);
    try std.testing.expectEqual(@as(?usize, 2), log.active_window);
    try std.testing.expectEqual(@as(?usize, 2), log.renamed_window);
    try std.testing.expectEqualStrings("editor tab", log.renamed_name.items);
}

test "block_end list-windows reply removes windows absent from the full refresh" {
    var col = Collector{ .alloc = std.testing.allocator };
    defer col.deinit();
    var log = EventLog{ .alloc = std.testing.allocator };
    defer log.deinit();
    var s = Session.init(std.testing.allocator, col.sink(), 80, 24);
    defer s.deinit();
    s.events = log.eventSink();

    try s.feed(
        "%begin 1 1 0\n" ++
            "@1\t0\tb25e,80x24,0,0,1\told\n" ++
            "@2\t1\tb25e,80x24,0,0,2\tkeep\n" ++
            "%end 1 1 0\n",
    );
    try std.testing.expectEqual(@as(usize, 2), s.windowCount());

    try s.feed("%begin 2 2 0\n@2\t1\tb25e,80x24,0,0,2\tkeep\n%end 2 2 0\n");
    try std.testing.expectEqual(@as(usize, 1), s.windowCount());
    try std.testing.expect(s.findWindow(1) == null);
    try std.testing.expect(s.findWindow(2) != null);
    try std.testing.expectEqual(@as(?usize, 1), log.closed_window);
}

test "capture-pane reply is routed to the pane sink (scrollback seed)" {
    var col = Collector{ .alloc = std.testing.allocator };
    defer col.deinit();
    var s = Session.init(std.testing.allocator, col.sink(), 80, 24);
    defer s.deinit();

    try s.capturePaneScreen(5, .primary, false);
    try std.testing.expect(std.mem.indexOf(u8, s.pendingCommands(), "capture-pane -p -e -q -t %5\n") != null);

    // The capture-pane reply: a %begin/%end block of plain pane content. It is
    // not a window list, so it routes to the queued pane (%5), prefixed with a
    // primary-screen switch + clear+home so it paints from the top-left.
    try s.feed("%begin 1 1 0\nline-a\nline-b\n%end 1 1 0\n");
    try std.testing.expectEqual(@as(usize, 5), col.last_pane);
    try std.testing.expectEqualSlices(u8, "\x1b[?1049l\x1b[0m\x1b[2J\x1b[Hline-a\r\nline-b\x1b[0m", col.buf.items);
}

test "current alternate capture enters alternate screen before seeding" {
    var col = Collector{ .alloc = std.testing.allocator };
    defer col.deinit();
    var s = Session.init(std.testing.allocator, col.sink(), 80, 24);
    defer s.deinit();

    try s.capturePaneScreen(5, .alternate, false);
    try std.testing.expect(std.mem.indexOf(u8, s.pendingCommands(), "capture-pane -p -e -q -t %5\n") != null);

    try s.feed("%begin 1 1 0\ncodex\nready\n%end 1 1 0\n");
    try std.testing.expectEqual(@as(usize, 5), col.last_pane);
    try std.testing.expectEqualSlices(u8, "\x1b[?1049h\x1b[0m\x1b[2J\x1b[Hcodex\r\nready\x1b[0m", col.buf.items);
}

test "EventSink default is a silent no-op" {
    var col = Collector{ .alloc = std.testing.allocator };
    defer col.deinit();
    var s = Session.init(std.testing.allocator, col.sink(), 80, 24);
    defer s.deinit();
    // No events sink set; these must not crash.
    try s.feed("%window-renamed @1 x\n");
    try s.feed("%window-pane-changed @1 %2\n");
}

test "list-panes reply drives onPaneMeta per pane" {
    var col = Collector{ .alloc = std.testing.allocator };
    defer col.deinit();
    var log = EventLog{ .alloc = std.testing.allocator };
    defer log.deinit();
    var s = Session.init(std.testing.allocator, col.sink(), 80, 24);
    defer s.deinit();
    s.events = log.eventSink();

    // Reply to: list-panes -s -F "#{pane_id}\t#{pane_current_path}\t#{pane_current_command}"
    try s.feed(
        "%begin 9 9 0\n" ++
            "%1\t/home/u/proj\tnvim\n" ++
            "%2\t/var/log\ttail\n" ++
            "%end 9 9 0\n",
    );

    try std.testing.expectEqual(@as(usize, 2), log.pane_meta_count);
    try std.testing.expectEqual(@as(?usize, 2), log.last_pane_meta_id);
    try std.testing.expectEqualStrings("/var/log", log.last_pane_meta_path.items);
    try std.testing.expectEqualStrings("tail", log.last_pane_meta_cmd.items);
}

test "active alternate restore seeds saved primary first and restores TUI modes" {
    var col = Collector{ .alloc = std.testing.allocator };
    defer col.deinit();
    var s = Session.init(std.testing.allocator, col.sink(), 80, 24);
    defer s.deinit();

    try s.requestPaneSeed(5, false);
    try s.requestPaneSeed(5, false);
    try std.testing.expect(std.mem.indexOf(u8, s.pendingCommands(), "display-message -p -t %5 -F") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, s.pendingCommands(), "display-message -p -t %5 -F"));
    s.clearCommands();
    try s.feed(
        "%begin 1 1 0\n" ++
            // cursor x/y/visible/shape/blink; alt + saved cursor; terminal,
            // mouse, focus/paste, scroll region, and tab-stop state.
            "%5;12;7;0;bar;0;1;3;4;1;0;1;1;1;1;1;0;0;0;1;1;1;2;20;8,16\n" ++
            "%end 1 1 0\n",
    );

    const commands = s.pendingCommands();
    const saved_at = std.mem.indexOf(u8, commands, "capture-pane -p -e -q -a -t %5\n").?;
    const current_at = std.mem.indexOf(u8, commands, "capture-pane -p -e -q -t %5\n").?;
    try std.testing.expect(saved_at < current_at);

    // -a is tmux's saved/inactive grid. With alternate_on=1 that is the
    // primary shell, and its saved cursor must be positioned before ?1049h.
    try s.feed("%begin 2 2 0\nSHELL\n%end 2 2 0\n");
    try std.testing.expectEqualSlices(
        u8,
        "\x1b[?1049l\x1b[0m\x1b[2J\x1b[HSHELL\x1b[0m\x1b[5;4H",
        col.buf.items,
    );

    col.buf.clearRetainingCapacity();
    try s.feed("%begin 3 3 0\nTUI\n%end 3 3 0\n");
    try std.testing.expectEqualSlices(
        u8,
        "\x1b[?1049h\x1b[0m\x1b[2J\x1b[HTUI\x1b[0m" ++
            "\x1b[4h\x1b[?7l\x1b=\x1b[?1h" ++
            "\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1003h" ++
            "\x1b[?1005l\x1b[?1006l\x1b[?1006h" ++
            "\x1b[?1004h\x1b[?2004h\x1b[3;21r" ++
            "\x1b[3g\x1b[9G\x1bH\x1b[17G\x1bH" ++
            "\x1b[?6h\x1b[6 q\x1b[?12l\x1b[6;13H\x1b[?25l",
        col.buf.items,
    );
}

test "pane state accepts empty optional fields from tmux 3.2" {
    var col = Collector{ .alloc = std.testing.allocator };
    defer col.deinit();
    var s = Session.init(std.testing.allocator, col.sink(), 80, 24);
    defer s.deinit();

    try s.reply_queue.append(std.testing.allocator, .{ .pane_state = .{} });
    // cursor_shape, cursor_blinking, focus_flag, and bracketed_paste are empty
    // on tmux 3.2, while mouse/scroll/tab state remains available.
    try s.feed("%begin 1 1 0\n%0;10;0;1;;;1;7;0;0;1;0;0;0;1;1;0;0;0;1;;;1;3;8,16\n%end 1 1 0\n");

    const state = s.findPaneState(0).?;
    try std.testing.expect(state.alternate_on);
    try std.testing.expect(std.mem.indexOf(u8, state.restore.items, "\x1b[?1003h") != null);
    try std.testing.expect(std.mem.indexOf(u8, state.restore.items, "\x1b[?1006h") != null);
    try std.testing.expect(std.mem.indexOf(u8, state.restore.items, "\x1b[2;4r") != null);
    try std.testing.expect(std.mem.indexOf(u8, state.restore.items, "\x1b[?1004") == null);
    try std.testing.expectEqual(@as(usize, 0), s.pendingCommands().len);
}

test "a pending capture does not steal a list-panes reply (startup ordering)" {
    var col = Collector{ .alloc = std.testing.allocator };
    defer col.deinit();
    var log = EventLog{ .alloc = std.testing.allocator };
    defer log.deinit();
    var s = Session.init(std.testing.allocator, col.sink(), 80, 24);
    defer s.deinit();
    s.events = log.eventSink();

    // The list-panes command is queued before captures, but captures may be
    // queued during the earlier list-windows reconcile before the list-panes
    // reply arrives. The typed command FIFO must route the reply to pane
    // metadata, NOT consume a capture seed.
    try s.reply_queue.append(std.testing.allocator, .pane_list);
    try s.capturePaneScreen(1, .primary, false);
    try s.capturePaneScreen(2, .primary, false);
    try s.feed("%begin 7 7 0\n%1\t/home/u\tnvim\n%2\t/var/log\ttail\n%end 7 7 0\n");

    try std.testing.expectEqual(@as(usize, 2), log.pane_meta_count);
    try std.testing.expectEqual(@as(usize, 2), s.reply_queue.items.len); // captures untouched
    try std.testing.expectEqual(@as(usize, 0), col.buf.items.len); // no capture seed written
}

test "split-window reply cannot be stolen by a later capture-pane" {
    var col = Collector{ .alloc = std.testing.allocator };
    defer col.deinit();
    var s = Session.init(std.testing.allocator, col.sink(), 80, 24);
    defer s.deinit();

    try s.splitPane(1, .horizontal);
    try s.capturePaneScreen(2, .primary, false);

    // A split-window command can reply with the new pane id while the layout
    // reconcile has already queued a capture for that pane. The split reply
    // belongs to the ignored split command, not to the later capture.
    try s.feed("%begin 3 3 0\n%2\n%end 3 3 0\n");

    try std.testing.expectEqual(@as(usize, 0), col.buf.items.len);
    try std.testing.expectEqual(@as(usize, 1), s.reply_queue.items.len);

    try s.feed("%begin 4 4 0\nreal pane\n%end 4 4 0\n");
    try std.testing.expectEqual(@as(usize, 2), col.last_pane);
    try std.testing.expectEqualSlices(u8, "\x1b[?1049l\x1b[0m\x1b[2J\x1b[Hreal pane\x1b[0m", col.buf.items);
}

test "list-panes reply is parsed even if stale replies precede it" {
    var col = Collector{ .alloc = std.testing.allocator };
    defer col.deinit();
    var log = EventLog{ .alloc = std.testing.allocator };
    defer log.deinit();
    var s = Session.init(std.testing.allocator, col.sink(), 80, 24);
    defer s.deinit();
    s.events = log.eventSink();

    try s.reply_queue.append(std.testing.allocator, .ignore);
    try s.capturePaneScreen(44, .primary, false);
    try s.reply_queue.append(std.testing.allocator, .pane_list);

    try s.feed("%begin 1 1 0\n%44     /data/xzg_data/Plant-Root-Atlas-Project/01.gene-family-analysis zsh\n%end 1 1 0\n");

    try std.testing.expectEqual(@as(usize, 1), log.pane_meta_count);
    try std.testing.expectEqual(@as(?usize, 44), log.last_pane_meta_id);
    try std.testing.expectEqualStrings("zsh", log.last_pane_meta_cmd.items);
    try std.testing.expectEqual(@as(usize, 0), col.buf.items.len);
    try std.testing.expectEqual(@as(usize, 1), s.reply_queue.items.len);
}

test "pane metadata is never seeded as capture content" {
    var col = Collector{ .alloc = std.testing.allocator };
    defer col.deinit();
    var log = EventLog{ .alloc = std.testing.allocator };
    defer log.deinit();
    var s = Session.init(std.testing.allocator, col.sink(), 80, 24);
    defer s.deinit();
    s.events = log.eventSink();

    try s.capturePaneScreen(44, .primary, false);
    try s.feed("%begin 1 1 0\n%44     /data/xzg_data/Plant-Root-Atlas-Project/01.gene-family-analysis zsh\n%end 1 1 0\n");

    try std.testing.expectEqual(@as(usize, 1), log.pane_meta_count);
    try std.testing.expectEqual(@as(?usize, 44), log.last_pane_meta_id);
    try std.testing.expectEqualStrings("/data/xzg_data/Plant-Root-Atlas-Project/01.gene-family-analysis", log.last_pane_meta_path.items);
    try std.testing.expectEqualStrings("zsh", log.last_pane_meta_cmd.items);
    try std.testing.expectEqual(@as(usize, 0), col.buf.items.len);
    try std.testing.expectEqual(@as(usize, 1), s.reply_queue.items.len);
}

test "an empty or errored pane-list reply does not consume a later capture" {
    var col = Collector{ .alloc = std.testing.allocator };
    defer col.deinit();
    var s = Session.init(std.testing.allocator, col.sink(), 80, 24);
    defer s.deinit();

    try s.reply_queue.append(std.testing.allocator, .pane_list);
    try s.capturePaneScreen(5, .primary, false);
    try s.feed("%begin 7 7 0\n%end 7 7 0\n");
    try std.testing.expectEqual(@as(usize, 1), s.reply_queue.items.len);
    try std.testing.expectEqual(@as(usize, 0), col.buf.items.len);

    try s.feed("%begin 8 8 0\nline-a\n%end 8 8 0\n");
    try std.testing.expectEqualSlices(u8, "\x1b[?1049l\x1b[0m\x1b[2J\x1b[Hline-a\x1b[0m", col.buf.items);

    col.buf.clearRetainingCapacity();
    try s.reply_queue.append(std.testing.allocator, .pane_list);
    try s.capturePaneScreen(6, .primary, false);
    try s.feed("%begin 9 9 0\nboom\n%error 9 9 0\n");
    try std.testing.expectEqual(@as(usize, 1), s.reply_queue.items.len);

    try s.feed("%begin 10 10 0\nline-b\n%end 10 10 0\n");
    try std.testing.expectEqualSlices(u8, "\x1b[?1049l\x1b[0m\x1b[2J\x1b[Hline-b\x1b[0m", col.buf.items);
}

test "a realistic capture reply is seeded even with pane-list-like ids elsewhere" {
    var col = Collector{ .alloc = std.testing.allocator };
    defer col.deinit();
    var log = EventLog{ .alloc = std.testing.allocator };
    defer log.deinit();
    var s = Session.init(std.testing.allocator, col.sink(), 80, 24);
    defer s.deinit();
    s.events = log.eventSink();

    try s.capturePaneScreen(5, .primary, false);
    // Real scrollback: NOT every line is `%<id>\t..`, so it's a capture, not pane-list.
    try s.feed("%begin 1 1 0\n$ ls\nfile.txt  %notapaneline\n%end 1 1 0\n");

    try std.testing.expectEqual(@as(usize, 0), log.pane_meta_count); // not pane-list
    try std.testing.expectEqual(@as(usize, 0), s.reply_queue.items.len); // capture consumed
    try std.testing.expect(std.mem.indexOf(u8, col.buf.items, "file.txt") != null); // seeded
}

test "start enqueues a list-panes metadata query" {
    var col = Collector{ .alloc = std.testing.allocator };
    defer col.deinit();
    var s = Session.init(std.testing.allocator, col.sink(), 80, 24);
    defer s.deinit();
    try s.start();
    try std.testing.expect(std.mem.indexOf(u8, s.cmds.items, "list-panes -s -F") != null);
}

test "applyPaneList skips malformed lines and counts only valid pane-list entries" {
    var col = Collector{ .alloc = std.testing.allocator };
    defer col.deinit();
    var log = EventLog{ .alloc = std.testing.allocator };
    defer log.deinit();
    var s = Session.init(std.testing.allocator, col.sink(), 80, 24);
    defer s.deinit();
    s.events = log.eventSink();

    // All non-empty lines have the %<digits>\t shape (pass isPaneListReply), but
    // applyPaneList's deeper per-line checks filter the malformed ones:
    //   blank line              — skipped (ignored by both predicates)
    //   %3\t/only-one-tab      — skipped by applyPaneList (missing second tab)
    //   %7\t/home\tbash        — valid → pane_meta_count == 1
    try s.feed(
        "%begin 5 5 0\n" ++
            "\n" ++
            "%3\t/only-one-tab\n" ++
            "%7\t/home\tbash\n" ++
            "%end 5 5 0\n",
    );

    try std.testing.expectEqual(@as(usize, 1), log.pane_meta_count);
    try std.testing.expectEqual(@as(?usize, 7), log.last_pane_meta_id);
    try std.testing.expectEqualStrings("/home", log.last_pane_meta_path.items);
    try std.testing.expectEqualStrings("bash", log.last_pane_meta_cmd.items);
}
