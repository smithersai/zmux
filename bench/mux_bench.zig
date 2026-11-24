const std = @import("std");
const bench = @import("bench");
const mux = @import("mux");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());

    var runner = try bench.Runner.init(allocator, io, "mux", argv);
    defer runner.deinit();

    // 1. Pure LayoutNode benchmarks (32-pane split tree JSON serialization & split/remove).
    {
        const root = try mux.LayoutNode.leafNode(allocator, "pane-0");
        defer {
            root.deinit(allocator);
            allocator.destroy(root);
        }
        var name_buf: [32]u8 = undefined;
        var split_buf: [32]u8 = undefined;
        for (1..32) |i| {
            const target = try std.fmt.bufPrint(&name_buf, "pane-{d}", .{i - 1});
            const new_pane = try std.fmt.allocPrint(allocator, "pane-{d}", .{i});
            defer allocator.free(new_pane);
            const split_id = try std.fmt.bufPrint(&split_buf, "split-{d}", .{i});
            const axis: mux.Axis = if (i % 2 == 0) .horizontal else .vertical;
            _ = try root.replaceLeafWithSplit(allocator, target, axis, new_pane, split_id);
        }

        const LayoutJsonCtx = struct { node: *const mux.LayoutNode, allocator: std.mem.Allocator };
        try runner.run("layoutNode_writeJson_32_panes", .{}, LayoutJsonCtx{ .node = root, .allocator = allocator }, struct {
            fn f(ctx: LayoutJsonCtx) !void {
                var out: std.Io.Writer.Allocating = .init(ctx.allocator);
                defer out.deinit();
                try ctx.node.writeJson(&out.writer);
                bench.doNotOptimize(out.written().ptr);
            }
        }.f);

        const SplitRemoveCtx = struct { node: *mux.LayoutNode, allocator: std.mem.Allocator };
        try runner.run("layoutNode_split_and_remove_leaf_32", .{}, SplitRemoveCtx{ .node = root, .allocator = allocator }, struct {
            fn f(ctx: SplitRemoveCtx) !void {
                _ = try ctx.node.replaceLeafWithSplit(ctx.allocator, "pane-31", .horizontal, "pane-tmp", "split-tmp");
                _ = ctx.node.removeLeaf(ctx.allocator, "pane-tmp");
            }
        }.f);
    }

    // 2. Command line parsing.
    const ParseCmdCtx = struct { allocator: std.mem.Allocator };
    try runner.run("parseCommandLine_split_window", .{}, ParseCmdCtx{ .allocator = allocator }, struct {
        fn f(ctx: ParseCmdCtx) !void {
            var parsed = try mux.Manager.parseCommandLine(ctx.allocator, "split-window -h /bin/sh -c 'echo hello'");
            bench.doNotOptimize(&parsed);
            parsed.deinit(ctx.allocator);
        }
    }.f);

    // 3. Manager benchmarks across 16 live panes (4 sessions x 2 windows x 2 panes) + 16 clients + 16 key bindings.
    {
        var manager = mux.Manager.init(allocator, io, null);
        defer manager.deinit();

        var pane_ids: std.ArrayList([]u8) = .empty;
        defer {
            for (pane_ids.items) |id| allocator.free(id);
            pane_ids.deinit(allocator);
        }

        const opts: mux.CreateOptions = .{
            .shell = "/bin/sh",
            .command = "exec sleep 60",
            .scrollback_bytes = 4096,
        };
        for (0..4) |s| {
            var title_buf: [32]u8 = undefined;
            const title = try std.fmt.bufPrint(&title_buf, "session-{d}", .{s});
            var s_opts = opts;
            s_opts.title = title;
            var p0 = try manager.createSessionPane(s_opts);
            defer p0.deinit();
            const s_id = try allocator.dupe(u8, p0.session_id);
            defer allocator.free(s_id);
            const p0_id = try allocator.dupe(u8, p0.pane_id);
            try pane_ids.append(allocator, p0_id);

            var p1 = try manager.splitPane(p0_id, .horizontal, opts);
            defer p1.deinit();
            try pane_ids.append(allocator, try allocator.dupe(u8, p1.pane_id));

            var p2 = try manager.newWindow(s_id, opts);
            defer p2.deinit();
            const p2_id = try allocator.dupe(u8, p2.pane_id);
            try pane_ids.append(allocator, p2_id);

            var p3 = try manager.splitPane(p2_id, .vertical, opts);
            defer p3.deinit();
            try pane_ids.append(allocator, try allocator.dupe(u8, p3.pane_id));
        }

        var attached_clients: std.ArrayList([]u8) = .empty;
        defer {
            for (attached_clients.items) |cid| {
                _ = manager.detachClient(cid);
                allocator.free(cid);
            }
            attached_clients.deinit(allocator);
        }
        for (pane_ids.items) |pid| {
            var snap = try manager.attachClient(pid, 40, 120);
            try attached_clients.append(allocator, try allocator.dupe(u8, snap.id));
            snap.deinit(allocator);
        }

        for (0..16) |k| {
            var key_buf: [8]u8 = undefined;
            const key = try std.fmt.bufPrint(&key_buf, "k{d}", .{k});
            try manager.bindKey("prefix", key, "split-window -h", false);
        }

        const last_pane_id = pane_ids.items[pane_ids.items.len - 1];
        const first_pane_id = pane_ids.items[0];
        const MgrIdCtx = struct { mgr: *mux.Manager, id: []const u8 };

        try runner.run("manager_find_last_of_16_panes", .{}, MgrIdCtx{ .mgr = &manager, .id = last_pane_id }, struct {
            fn f(ctx: MgrIdCtx) void {
                if (ctx.mgr.find(ctx.id)) |native| {
                    bench.doNotOptimize(native);
                    native.release();
                }
            }
        }.f);

        try runner.run("manager_find_by_session_name_16_panes", .{}, MgrIdCtx{ .mgr = &manager, .id = "session-3" }, struct {
            fn f(ctx: MgrIdCtx) void {
                if (ctx.mgr.find(ctx.id)) |native| {
                    bench.doNotOptimize(native);
                    native.release();
                }
            }
        }.f);

        const MgrMarkCtx = struct { mgr: *mux.Manager, id: []const u8, generation: u64 };
        const last_generation = blk: {
            const native = manager.find(last_pane_id).?;
            defer native.release();
            break :blk native.generation();
        };
        try runner.run("manager_markActivity_last_of_16_panes", .{}, MgrMarkCtx{ .mgr = &manager, .id = last_pane_id, .generation = last_generation }, struct {
            fn f(ctx: MgrMarkCtx) void {
                ctx.mgr.markActivity(ctx.id, ctx.generation, 1);
            }
        }.f);

        const MgrAllocCtx = struct { mgr: *mux.Manager, allocator: std.mem.Allocator };
        try runner.run("manager_snapshotJson_16_panes_16_clients", .{}, MgrAllocCtx{ .mgr = &manager, .allocator = allocator }, struct {
            fn f(ctx: MgrAllocCtx) !void {
                const json = try ctx.mgr.snapshotJson(ctx.allocator);
                bench.doNotOptimize(json.ptr);
                ctx.allocator.free(json);
            }
        }.f);

        try runner.run("manager_listJson_16_panes", .{}, MgrAllocCtx{ .mgr = &manager, .allocator = allocator }, struct {
            fn f(ctx: MgrAllocCtx) !void {
                const json = try ctx.mgr.listJson(ctx.allocator);
                bench.doNotOptimize(json.ptr);
                ctx.allocator.free(json);
            }
        }.f);

        try runner.run("manager_clientsJson_16_clients", .{}, MgrAllocCtx{ .mgr = &manager, .allocator = allocator }, struct {
            fn f(ctx: MgrAllocCtx) !void {
                const json = try ctx.mgr.clientsJson(ctx.allocator);
                bench.doNotOptimize(json.ptr);
                ctx.allocator.free(json);
            }
        }.f);

        try runner.run("manager_reapExitedPanes_16_panes", .{}, &manager, struct {
            fn f(m: *mux.Manager) void {
                m.reapExitedPanes();
            }
        }.f);

        const AttachDetachCtx = struct { mgr: *mux.Manager, allocator: std.mem.Allocator, pane_id: []const u8 };
        try runner.run("manager_attach_and_detach_client", .{}, AttachDetachCtx{
            .mgr = &manager,
            .allocator = allocator,
            .pane_id = last_pane_id,
        }, struct {
            fn f(ctx: AttachDetachCtx) !void {
                var snap = try ctx.mgr.attachClient(ctx.pane_id, 40, 120);
                defer snap.deinit(ctx.allocator);
                bench.doNotOptimize(ctx.mgr.detachClient(snap.id));
            }
        }.f);

        const SwitchCtx = struct { mgr: *mux.Manager, client_id: []const u8, a: []const u8, b: []const u8, toggle: bool = false };
        var sctx: SwitchCtx = .{
            .mgr = &manager,
            .client_id = attached_clients.items[attached_clients.items.len - 1],
            .a = first_pane_id,
            .b = last_pane_id,
        };
        try runner.run("manager_switchClient", .{}, &sctx, struct {
            fn f(ctx: *SwitchCtx) !void {
                ctx.toggle = !ctx.toggle;
                try ctx.mgr.switchClient(ctx.client_id, if (ctx.toggle) ctx.a else ctx.b);
            }
        }.f);
    }

    try runner.finish();
}
