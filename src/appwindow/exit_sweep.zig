//! Pure policy for the close-on-exit sweep: when may a terminal pane be
//! destroyed because its session ended?
//!
//! The historical rule was "`io_state` says exited AND the surface has a
//! child process". That second half is not enough on its own: `io_state`
//! becomes `.exited`/`.failed` for reasons that prove nothing about the child —
//! a transient PTY read failure, or a spurious end-of-stream from the PTY
//! backend. Windows ConPTY can surface either while the shell is still very
//! much alive, which made the sweep destroy a live tab (observed when a
//! foreground TUI such as `opencode` exited: the shell came back to its
//! prompt and the tab vanished anyway).
//!
//! So the rule is: a pane closes only when the OS has *proved* the child
//! exited (`Command.wait` returned a status — recorded by the surface as
//! `childExitConfirmed`). Deliberately a strict tightening: every input it now
//! rejects was previously a close, and it never authorises a close the old
//! rule would not have made.
//!
//! Zero project dependencies (std only), so it can be unit-tested standalone
//! with `zig test src/appwindow/exit_sweep.zig`.
const std = @import("std");

pub const SweepInputs = struct {
    /// The surface's IO layer reported end-of-stream, a broken pipe, or a
    /// read failure — i.e. `Surface.isExited()`.
    io_reported_exit: bool,
    /// `Command.hasProcess()`: a real child was spawned, so there is
    /// something whose exit can be proven. Virtual PTYs (tmux control panes,
    /// preview panes) report false and own their own lifetime.
    has_child_process: bool,
    /// A `Command.wait` call returned an exit status for that child.
    child_exit_confirmed: bool,
};

pub fn shouldAutoClose(in: SweepInputs) bool {
    if (!in.io_reported_exit) return false;
    // Only panes backed by a real child are swept; virtual/tmux panes manage
    // their own lifetime (matches the pre-existing rule).
    if (!in.has_child_process) return false;
    // The child is provably still running: the IO report was a backend
    // hiccup, not a session end. Keep the tab.
    return in.child_exit_confirmed;
}

test "exit_sweep: a proven child exit closes the pane" {
    try std.testing.expect(shouldAutoClose(.{
        .io_reported_exit = true,
        .has_child_process = true,
        .child_exit_confirmed = true,
    }));
}

test "exit_sweep: an unproven IO exit never closes a live tab" {
    // The bug: IO reported end-of-stream but the shell is still running.
    try std.testing.expect(!shouldAutoClose(.{
        .io_reported_exit = true,
        .has_child_process = true,
        .child_exit_confirmed = false,
    }));
}

test "exit_sweep: a running child with no IO report is left alone" {
    try std.testing.expect(!shouldAutoClose(.{
        .io_reported_exit = false,
        .has_child_process = true,
        .child_exit_confirmed = false,
    }));
    // Confirmed-exit proof without an IO report must not preempt the IO
    // layer's own bookkeeping (it drives the "Press Enter to reconnect" UI).
    try std.testing.expect(!shouldAutoClose(.{
        .io_reported_exit = false,
        .has_child_process = true,
        .child_exit_confirmed = true,
    }));
}

test "exit_sweep: panes without a real child are never swept" {
    try std.testing.expect(!shouldAutoClose(.{
        .io_reported_exit = true,
        .has_child_process = false,
        .child_exit_confirmed = false,
    }));
    try std.testing.expect(!shouldAutoClose(.{
        .io_reported_exit = true,
        .has_child_process = false,
        .child_exit_confirmed = true,
    }));
}
