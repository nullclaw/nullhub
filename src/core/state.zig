const std = @import("std");

// ─── Types ───────────────────────────────────────────────────────────────────

pub const InstanceEntry = struct {
    version: []const u8,
    auto_start: bool = false,
};

/// JSON-compatible shape used for serialization / deserialization.
/// `std.json.ArrayHashMap` carries `jsonStringify` and `jsonParse` so we can
/// round-trip through `std.json` without custom hooks.
const JsonState = struct {
    instances: std.json.ArrayHashMap(std.json.ArrayHashMap(InstanceEntry)),
};

/// Inner map type: instance-name → InstanceEntry.
const InstanceMap = std.StringArrayHashMap(InstanceEntry);

/// Outer map type: component-name → InstanceMap.
const ComponentMap = std.StringArrayHashMap(InstanceMap);

// ─── State ───────────────────────────────────────────────────────────────────

pub const State = struct {
    allocator: std.mem.Allocator,
    /// instances[component][name] = InstanceEntry
    instances: ComponentMap,
    path: []const u8,

    /// Create an empty State that will persist to `path`.
    pub fn init(allocator: std.mem.Allocator, path: []const u8) State {
        return .{
            .allocator = allocator,
            .instances = ComponentMap.init(allocator),
            .path = allocator.dupe(u8, path) catch @panic("OOM"),
        };
    }

    /// Free all owned strings and hashmaps.
    pub fn deinit(self: *State) void {
        var comp_it = self.instances.iterator();
        while (comp_it.next()) |comp_entry| {
            var inst_it = comp_entry.value_ptr.iterator();
            while (inst_it.next()) |inst_entry| {
                self.allocator.free(inst_entry.value_ptr.version);
                self.allocator.free(inst_entry.key_ptr.*);
            }
            comp_entry.value_ptr.deinit();
            self.allocator.free(comp_entry.key_ptr.*);
        }
        self.instances.deinit();
        self.allocator.free(self.path);
    }

    /// Read state from disk. If the file doesn't exist, return an empty state.
    pub fn load(allocator: std.mem.Allocator, path: []const u8) !State {
        const bytes = blk: {
            const file = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
                error.FileNotFound => return State.init(allocator, path),
                else => return err,
            };
            defer file.close();
            break :blk try file.readToEndAlloc(allocator, 4 * 1024 * 1024);
        };
        defer allocator.free(bytes);

        const parsed = try std.json.parseFromSlice(
            JsonState,
            allocator,
            bytes,
            .{ .allocate = .alloc_always },
        );
        defer parsed.deinit();

        // Copy into an owned State with duped strings.
        var state = State.init(allocator, path);
        errdefer state.deinit();

        var comp_it = parsed.value.instances.map.iterator();
        while (comp_it.next()) |comp_kv| {
            const comp_name = try allocator.dupe(u8, comp_kv.key_ptr.*);
            errdefer allocator.free(comp_name);

            var inner = InstanceMap.init(allocator);
            errdefer {
                var it = inner.iterator();
                while (it.next()) |e| {
                    allocator.free(e.value_ptr.version);
                    allocator.free(e.key_ptr.*);
                }
                inner.deinit();
            }

            var inst_it = comp_kv.value_ptr.map.iterator();
            while (inst_it.next()) |inst_kv| {
                const inst_name = try allocator.dupe(u8, inst_kv.key_ptr.*);
                errdefer allocator.free(inst_name);
                const entry = InstanceEntry{
                    .version = try allocator.dupe(u8, inst_kv.value_ptr.version),
                    .auto_start = inst_kv.value_ptr.auto_start,
                };
                try inner.put(inst_name, entry);
            }

            try state.instances.put(comp_name, inner);
        }

        return state;
    }

    /// Atomic save: serialize to JSON, write to `{path}.tmp`, rename over
    /// the real path. If NullHub crashes mid-write the original is preserved.
    pub fn save(self: *State) !void {
        // Build the JSON-friendly structure. We reference the strings we
        // already own — they live long enough for serialization.
        var json_outer = std.json.ArrayHashMap(std.json.ArrayHashMap(InstanceEntry)){};
        defer {
            // Free inner maps first, then the outer map.
            for (json_outer.map.values()) |*inner| {
                inner.deinit(self.allocator);
            }
            json_outer.deinit(self.allocator);
        }

        var comp_it = self.instances.iterator();
        while (comp_it.next()) |comp_entry| {
            var json_inner = std.json.ArrayHashMap(InstanceEntry){};
            errdefer json_inner.deinit(self.allocator);

            var inst_it = comp_entry.value_ptr.iterator();
            while (inst_it.next()) |inst_entry| {
                try json_inner.map.put(self.allocator, inst_entry.key_ptr.*, inst_entry.value_ptr.*);
            }

            try json_outer.map.put(self.allocator, comp_entry.key_ptr.*, json_inner);
        }

        const json_state = JsonState{ .instances = json_outer };
        const json_bytes = try std.json.Stringify.valueAlloc(
            self.allocator,
            json_state,
            .{ .whitespace = .indent_2 },
        );
        defer self.allocator.free(json_bytes);

        // Write to temp file, then atomic rename.
        const tmp_path = try std.fmt.allocPrint(self.allocator, "{s}.tmp", .{self.path});
        defer self.allocator.free(tmp_path);

        {
            const file = try std.fs.createFileAbsolute(tmp_path, .{});
            defer file.close();
            try file.writeAll(json_bytes);
        }

        try std.fs.renameAbsolute(tmp_path, self.path);
    }

    /// Register a new instance under `component/name`. Dupes all strings.
    pub fn addInstance(
        self: *State,
        component: []const u8,
        name: []const u8,
        entry: InstanceEntry,
    ) !void {
        // Look up or create the component bucket.
        const inner_ptr = blk: {
            if (self.instances.getPtr(component)) |ptr| break :blk ptr;
            const owned_comp = try self.allocator.dupe(u8, component);
            errdefer self.allocator.free(owned_comp);
            try self.instances.put(owned_comp, InstanceMap.init(self.allocator));
            break :blk self.instances.getPtr(component).?;
        };

        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        const owned_entry = InstanceEntry{
            .version = try self.allocator.dupe(u8, entry.version),
            .auto_start = entry.auto_start,
        };
        try inner_ptr.put(owned_name, owned_entry);
    }

    /// Remove an instance. Returns `true` if the entry existed.
    pub fn removeInstance(self: *State, component: []const u8, name: []const u8) bool {
        const inner = self.instances.getPtr(component) orelse return false;
        const entry = inner.fetchSwapRemove(name) orelse return false;

        self.allocator.free(entry.value.version);
        self.allocator.free(entry.key);

        // If this was the last instance, remove the component key too.
        if (inner.count() == 0) {
            const comp = self.instances.fetchSwapRemove(component).?;
            var map = comp.value;
            map.deinit();
            self.allocator.free(comp.key);
        }

        return true;
    }

    /// Look up an instance.
    pub fn getInstance(self: *State, component: []const u8, name: []const u8) ?InstanceEntry {
        const inner = self.instances.get(component) orelse return null;
        return inner.get(name);
    }

    /// Update an existing instance entry. Returns `true` if found, `false` otherwise.
    pub fn updateInstance(
        self: *State,
        component: []const u8,
        name: []const u8,
        entry: InstanceEntry,
    ) !bool {
        const inner = self.instances.getPtr(component) orelse return false;
        const ptr = inner.getPtr(name) orelse return false;

        // Free old version string, replace with new one.
        self.allocator.free(ptr.version);
        ptr.version = try self.allocator.dupe(u8, entry.version);
        ptr.auto_start = entry.auto_start;
        return true;
    }

    /// Return all component names. Caller must free the returned slice
    /// (but NOT the strings themselves — they are owned by the State).
    pub fn componentNames(self: *State) ![][]const u8 {
        const keys = self.instances.keys();
        const result = try self.allocator.alloc([]const u8, keys.len);
        @memcpy(result, keys);
        return result;
    }

    /// Return all instance names under a component. Returns `null` if
    /// the component doesn't exist. Caller must free the returned slice.
    pub fn instanceNames(self: *State, component: []const u8) !?[][]const u8 {
        const inner = self.instances.getPtr(component) orelse return null;
        const keys = inner.keys();
        const result = try self.allocator.alloc([]const u8, keys.len);
        @memcpy(result, keys);
        return result;
    }
};

// ─── Tests ───────────────────────────────────────────────────────────────────

fn testPath(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    const tmp = "/tmp/nullhub-state-test";
    std.fs.deleteTreeAbsolute(tmp) catch {};
    try std.fs.makeDirAbsolute(tmp);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ tmp, name });
}

fn cleanupTestDir() void {
    std.fs.deleteTreeAbsolute("/tmp/nullhub-state-test") catch {};
}

test "add instances, save, load, verify round-trip" {
    const allocator = std.testing.allocator;
    const path = try testPath(allocator, "state.json");
    defer allocator.free(path);
    defer cleanupTestDir();

    // Create and populate
    {
        var s = State.init(allocator, path);
        defer s.deinit();

        try s.addInstance("nullclaw", "my-agent", .{ .version = "2026.3.1", .auto_start = true });
        try s.addInstance("nullclaw", "staging", .{ .version = "2026.3.1", .auto_start = false });
        try s.addInstance("nulltickets", "tracker", .{ .version = "0.1.0", .auto_start = true });

        try s.save();
    }

    // Load and verify
    {
        var s = try State.load(allocator, path);
        defer s.deinit();

        const agent = s.getInstance("nullclaw", "my-agent");
        try std.testing.expect(agent != null);
        try std.testing.expectEqualStrings("2026.3.1", agent.?.version);
        try std.testing.expect(agent.?.auto_start == true);

        const staging = s.getInstance("nullclaw", "staging");
        try std.testing.expect(staging != null);
        try std.testing.expectEqualStrings("2026.3.1", staging.?.version);
        try std.testing.expect(staging.?.auto_start == false);

        const tracker = s.getInstance("nulltickets", "tracker");
        try std.testing.expect(tracker != null);
        try std.testing.expectEqualStrings("0.1.0", tracker.?.version);
        try std.testing.expect(tracker.?.auto_start == true);
    }
}

test "remove instance, save, load, verify gone" {
    const allocator = std.testing.allocator;
    const path = try testPath(allocator, "state.json");
    defer allocator.free(path);
    defer cleanupTestDir();

    {
        var s = State.init(allocator, path);
        defer s.deinit();

        try s.addInstance("nullclaw", "my-agent", .{ .version = "1.0.0", .auto_start = true });
        try s.addInstance("nullclaw", "staging", .{ .version = "1.0.0", .auto_start = false });

        try std.testing.expect(s.removeInstance("nullclaw", "my-agent"));
        try s.save();
    }

    {
        var s = try State.load(allocator, path);
        defer s.deinit();

        try std.testing.expect(s.getInstance("nullclaw", "my-agent") == null);

        const staging = s.getInstance("nullclaw", "staging");
        try std.testing.expect(staging != null);
        try std.testing.expectEqualStrings("1.0.0", staging.?.version);
    }
}

test "update instance version, save, load, verify" {
    const allocator = std.testing.allocator;
    const path = try testPath(allocator, "state.json");
    defer allocator.free(path);
    defer cleanupTestDir();

    {
        var s = State.init(allocator, path);
        defer s.deinit();

        try s.addInstance("nullclaw", "my-agent", .{ .version = "1.0.0", .auto_start = false });
        const updated = try s.updateInstance("nullclaw", "my-agent", .{ .version = "2.0.0", .auto_start = true });
        try std.testing.expect(updated);
        try s.save();
    }

    {
        var s = try State.load(allocator, path);
        defer s.deinit();

        const entry = s.getInstance("nullclaw", "my-agent");
        try std.testing.expect(entry != null);
        try std.testing.expectEqualStrings("2.0.0", entry.?.version);
        try std.testing.expect(entry.?.auto_start == true);
    }
}

test "load non-existent file returns empty state" {
    const allocator = std.testing.allocator;
    const path = "/tmp/nullhub-state-test-nonexistent/state.json";

    var s = try State.load(allocator, path);
    defer s.deinit();

    try std.testing.expectEqual(@as(usize, 0), s.instances.count());
}

test "atomic save writes via temp file" {
    const allocator = std.testing.allocator;
    const path = try testPath(allocator, "state.json");
    defer allocator.free(path);
    defer cleanupTestDir();

    var s = State.init(allocator, path);
    defer s.deinit();

    try s.addInstance("comp", "inst", .{ .version = "1.0.0" });
    try s.save();

    // The temp file should NOT still exist after a successful save.
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    defer allocator.free(tmp_path);

    const tmp_exists = blk: {
        const f = std.fs.openFileAbsolute(tmp_path, .{}) catch |err| switch (err) {
            error.FileNotFound => break :blk false,
            else => return err,
        };
        f.close();
        break :blk true;
    };
    try std.testing.expect(!tmp_exists);

    // The real file should exist and be valid JSON.
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    const bytes = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(bytes);

    const parsed = try std.json.parseFromSlice(JsonState, allocator, bytes, .{ .allocate = .alloc_always });
    defer parsed.deinit();

    const entry = parsed.value.instances.map.get("comp").?.map.get("inst");
    try std.testing.expect(entry != null);
    try std.testing.expectEqualStrings("1.0.0", entry.?.version);
}

test "multiple components with multiple instances" {
    const allocator = std.testing.allocator;
    const path = try testPath(allocator, "state.json");
    defer allocator.free(path);
    defer cleanupTestDir();

    {
        var s = State.init(allocator, path);
        defer s.deinit();

        try s.addInstance("alpha", "a1", .{ .version = "0.1.0", .auto_start = true });
        try s.addInstance("alpha", "a2", .{ .version = "0.2.0", .auto_start = false });
        try s.addInstance("beta", "b1", .{ .version = "1.0.0", .auto_start = true });
        try s.addInstance("beta", "b2", .{ .version = "1.1.0", .auto_start = false });
        try s.addInstance("gamma", "g1", .{ .version = "3.0.0", .auto_start = true });

        const comps = try s.componentNames();
        defer allocator.free(comps);
        try std.testing.expectEqual(@as(usize, 3), comps.len);

        const alpha_names = (try s.instanceNames("alpha")).?;
        defer allocator.free(alpha_names);
        try std.testing.expectEqual(@as(usize, 2), alpha_names.len);

        const beta_names = (try s.instanceNames("beta")).?;
        defer allocator.free(beta_names);
        try std.testing.expectEqual(@as(usize, 2), beta_names.len);

        try s.save();
    }

    {
        var s = try State.load(allocator, path);
        defer s.deinit();

        // Verify everything round-tripped.
        try std.testing.expectEqualStrings("0.1.0", s.getInstance("alpha", "a1").?.version);
        try std.testing.expectEqualStrings("0.2.0", s.getInstance("alpha", "a2").?.version);
        try std.testing.expectEqualStrings("1.0.0", s.getInstance("beta", "b1").?.version);
        try std.testing.expectEqualStrings("1.1.0", s.getInstance("beta", "b2").?.version);
        try std.testing.expectEqualStrings("3.0.0", s.getInstance("gamma", "g1").?.version);

        // Non-existent lookups.
        try std.testing.expect(s.getInstance("alpha", "nope") == null);
        try std.testing.expect(s.getInstance("nope", "a1") == null);

        const missing = try s.instanceNames("nonexistent");
        try std.testing.expect(missing == null);

        // Update non-existent returns false.
        const nope = try s.updateInstance("nope", "nope", .{ .version = "0.0.0" });
        try std.testing.expect(!nope);

        // Remove non-existent returns false.
        try std.testing.expect(!s.removeInstance("nope", "nope"));
    }
}

test "remove last instance removes component" {
    const allocator = std.testing.allocator;
    const path = try testPath(allocator, "state.json");
    defer allocator.free(path);
    defer cleanupTestDir();

    var s = State.init(allocator, path);
    defer s.deinit();

    try s.addInstance("comp", "only", .{ .version = "1.0.0" });
    try std.testing.expect(s.removeInstance("comp", "only"));

    // Component should be gone entirely.
    try std.testing.expectEqual(@as(usize, 0), s.instances.count());
    try std.testing.expect(s.getInstance("comp", "only") == null);
}
