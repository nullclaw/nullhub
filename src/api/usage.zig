const std = @import("std");
const std_compat = @import("compat");
const state_mod = @import("../core/state.zig");
const paths_mod = @import("../core/paths.zig");
const helpers = @import("helpers.zig");
const instances_api = @import("instances.zig");

const ApiResponse = helpers.ApiResponse;
const appendEscaped = helpers.appendEscaped;

const ModelAgg = struct {
    provider: []const u8,
    model: []const u8,
    prompt_tokens: u64 = 0,
    completion_tokens: u64 = 0,
    total_tokens: u64 = 0,
    requests: u64 = 0,
    last_used: i64 = 0,
};

const InstanceAgg = struct {
    component: []const u8,
    name: []const u8,
    prompt_tokens: u64 = 0,
    completion_tokens: u64 = 0,
    total_tokens: u64 = 0,
    requests: u64 = 0,
};

const TimeseriesBucket = struct {
    prompt_tokens: u64 = 0,
    completion_tokens: u64 = 0,
    total_tokens: u64 = 0,
    requests: u64 = 0,
};

/// GET /api/usage?window=24h|7d|30d|all
/// Aggregates token usage across all instances.
pub fn handleGlobalUsage(allocator: std.mem.Allocator, s: *state_mod.State, paths: paths_mod.Paths, target: []const u8) ApiResponse {
    const now_ts = std_compat.time.timestamp();
    const window = instances_api.parseUsageWindow(target);
    const min_ts = instances_api.usageWindowMinTs(window, now_ts);
    const use_hourly = instances_api.isShortUsageWindow(window);

    // ── Accumulators ────────────────────────────────────────────────────
    var model_map: std.StringHashMapUnmanaged(ModelAgg) = .{};
    defer {
        var it = model_map.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.provider);
            allocator.free(entry.value_ptr.model);
        }
        model_map.deinit(allocator);
    }

    var inst_map: std.StringHashMapUnmanaged(InstanceAgg) = .{};
    defer {
        var it = inst_map.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.component);
            allocator.free(entry.value_ptr.name);
        }
        inst_map.deinit(allocator);
    }

    var ts_map: std.AutoHashMapUnmanaged(i64, TimeseriesBucket) = .{};
    defer ts_map.deinit(allocator);

    var grand_prompt: u64 = 0;
    var grand_completion: u64 = 0;
    var grand_total: u64 = 0;
    var grand_requests: u64 = 0;

    // ── Iterate all instances ───────────────────────────────────────────
    var comp_it = s.instances.iterator();
    while (comp_it.next()) |comp_entry| {
        const component = comp_entry.key_ptr.*;
        var name_it = comp_entry.value_ptr.iterator();
        while (name_it.next()) |name_entry| {
            const name = name_entry.key_ptr.*;

            const inst_dir = paths.instanceDir(allocator, component, name) catch return helpers.serverError();
            defer allocator.free(inst_dir);
            const ledger_path = instances_api.resolveUsageLedgerPath(allocator, inst_dir) catch return helpers.serverError();
            defer allocator.free(ledger_path);
            const cache_path = instances_api.usageCachePath(allocator, paths, component, name) catch return helpers.serverError();
            defer allocator.free(cache_path);

            // Load or rebuild cache snapshot
            var snapshot = instances_api.emptyUsageCache(now_ts);
            var has_cache = false;
            if (instances_api.loadUsageCacheSnapshot(allocator, cache_path, now_ts) catch null) |loaded| {
                snapshot = loaded;
                has_cache = true;
            }

            defer snapshot.deinit(allocator);

            var ledger_size: u64 = 0;
            var ledger_mtime_ns: i64 = 0;
            var ledger_exists = false;
            const ledger_file = std_compat.fs.openFileAbsolute(ledger_path, .{}) catch |err| switch (err) {
                error.FileNotFound => null,
                else => return helpers.serverError(),
            };
            if (ledger_file) |file| {
                defer file.close();
                const stat = file.stat() catch return helpers.serverError();
                ledger_exists = true;
                ledger_size = stat.size;
                ledger_mtime_ns = @intCast(stat.mtime);
            }
            var should_rebuild = false;
            if (ledger_exists) {
                if (!has_cache) {
                    should_rebuild = true;
                } else if (snapshot.ledger_size != ledger_size or snapshot.ledger_mtime_ns != ledger_mtime_ns) {
                    should_rebuild = true;
                }
            } else if (has_cache) {
                snapshot.deinit(allocator);
                snapshot = instances_api.emptyUsageCache(now_ts);
                has_cache = false;
            }

            if (should_rebuild) {
                if (has_cache) snapshot.deinit(allocator);
                snapshot = instances_api.rebuildUsageCacheSnapshot(allocator, ledger_path, ledger_size, ledger_mtime_ns, now_ts) catch return helpers.serverError();
                has_cache = true;
                instances_api.writeUsageCacheSnapshot(allocator, cache_path, &snapshot) catch {};
            }

            const source = if (use_hourly) snapshot.hourly else snapshot.daily;
            for (source) |record| {
                if (min_ts) |cutoff| {
                    if (record.last_used < cutoff) continue;
                }

                const provider = if (record.provider.len > 0) record.provider else "unknown";
                const model = if (record.model.len > 0) record.model else "unknown";
                const record_total: u64 = if (record.total_tokens > 0) record.total_tokens else record.prompt_tokens + record.completion_tokens;
                const req_count: u64 = if (record.requests > 0) record.requests else 1;

                grand_prompt += record.prompt_tokens;
                grand_completion += record.completion_tokens;
                grand_total += record_total;
                grand_requests += req_count;

                // by_model
                accumulateModel(allocator, &model_map, provider, model, record.prompt_tokens, record.completion_tokens, record_total, req_count, record.last_used);
                // by_instance
                accumulateInstance(allocator, &inst_map, component, name, record.prompt_tokens, record.completion_tokens, record_total, req_count);
                // timeseries
                accumulateTimeseries(allocator, &ts_map, record.bucket_start, record.prompt_tokens, record.completion_tokens, record_total, req_count);
            }
        }
    }

    // ── Serialize JSON ──────────────────────────────────────────────────
    return serializeResponse(allocator, window, now_ts, grand_prompt, grand_completion, grand_total, grand_requests, &model_map, &inst_map, &ts_map);
}

fn accumulateModel(
    allocator: std.mem.Allocator,
    map: *std.StringHashMapUnmanaged(ModelAgg),
    provider: []const u8,
    model: []const u8,
    prompt: u64,
    completion: u64,
    total: u64,
    requests: u64,
    last_used: i64,
) void {
    const key = std.fmt.allocPrint(allocator, "{s}\x1f{s}", .{ provider, model }) catch return;
    if (map.getPtr(key)) |agg| {
        allocator.free(key);
        agg.prompt_tokens += prompt;
        agg.completion_tokens += completion;
        agg.total_tokens += total;
        agg.requests += requests;
        if (last_used > agg.last_used) agg.last_used = last_used;
    } else {
        const p = allocator.dupe(u8, provider) catch {
            allocator.free(key);
            return;
        };
        const m = allocator.dupe(u8, model) catch {
            allocator.free(key);
            allocator.free(p);
            return;
        };
        map.put(allocator, key, .{
            .provider = p,
            .model = m,
            .prompt_tokens = prompt,
            .completion_tokens = completion,
            .total_tokens = total,
            .requests = requests,
            .last_used = last_used,
        }) catch {
            allocator.free(key);
            allocator.free(p);
            allocator.free(m);
        };
    }
}

fn accumulateInstance(
    allocator: std.mem.Allocator,
    map: *std.StringHashMapUnmanaged(InstanceAgg),
    component: []const u8,
    name: []const u8,
    prompt: u64,
    completion: u64,
    total: u64,
    requests: u64,
) void {
    const ikey = std.fmt.allocPrint(allocator, "{s}\x1f{s}", .{ component, name }) catch return;
    if (map.getPtr(ikey)) |agg| {
        allocator.free(ikey);
        agg.prompt_tokens += prompt;
        agg.completion_tokens += completion;
        agg.total_tokens += total;
        agg.requests += requests;
    } else {
        const c = allocator.dupe(u8, component) catch {
            allocator.free(ikey);
            return;
        };
        const n = allocator.dupe(u8, name) catch {
            allocator.free(ikey);
            allocator.free(c);
            return;
        };
        map.put(allocator, ikey, .{
            .component = c,
            .name = n,
            .prompt_tokens = prompt,
            .completion_tokens = completion,
            .total_tokens = total,
            .requests = requests,
        }) catch {
            allocator.free(ikey);
            allocator.free(c);
            allocator.free(n);
        };
    }
}

fn accumulateTimeseries(
    allocator: std.mem.Allocator,
    map: *std.AutoHashMapUnmanaged(i64, TimeseriesBucket),
    bucket_start: i64,
    prompt: u64,
    completion: u64,
    total: u64,
    requests: u64,
) void {
    if (map.getPtr(bucket_start)) |b| {
        b.prompt_tokens += prompt;
        b.completion_tokens += completion;
        b.total_tokens += total;
        b.requests += requests;
    } else {
        map.put(allocator, bucket_start, .{
            .prompt_tokens = prompt,
            .completion_tokens = completion,
            .total_tokens = total,
            .requests = requests,
        }) catch {};
    }
}

fn serializeResponse(
    allocator: std.mem.Allocator,
    window: []const u8,
    now_ts: i64,
    grand_prompt: u64,
    grand_completion: u64,
    grand_total: u64,
    grand_requests: u64,
    model_map: *std.StringHashMapUnmanaged(ModelAgg),
    inst_map: *std.StringHashMapUnmanaged(InstanceAgg),
    ts_map: *std.AutoHashMapUnmanaged(i64, TimeseriesBucket),
) ApiResponse {
    var buf = std.array_list.Managed(u8).init(allocator);

    buf.appendSlice("{\"window\":\"") catch return helpers.serverError();
    appendEscaped(&buf, window) catch return helpers.serverError();
    buf.print("\",\"generated_at\":{d}", .{now_ts}) catch return helpers.serverError();

    // totals
    buf.print(",\"totals\":{{\"prompt_tokens\":{d},\"completion_tokens\":{d},\"total_tokens\":{d},\"requests\":{d}}}", .{
        grand_prompt, grand_completion, grand_total, grand_requests,
    }) catch return helpers.serverError();

    // by_model
    buf.appendSlice(",\"by_model\":[") catch return helpers.serverError();
    {
        var it = model_map.iterator();
        var first = true;
        while (it.next()) |entry| {
            if (!first) buf.append(',') catch return helpers.serverError();
            first = false;
            const v = entry.value_ptr.*;
            buf.appendSlice("{\"provider\":\"") catch return helpers.serverError();
            appendEscaped(&buf, v.provider) catch return helpers.serverError();
            buf.appendSlice("\",\"model\":\"") catch return helpers.serverError();
            appendEscaped(&buf, v.model) catch return helpers.serverError();
            buf.print("\",\"prompt_tokens\":{d},\"completion_tokens\":{d},\"total_tokens\":{d},\"requests\":{d},\"last_used\":{d}}}", .{
                v.prompt_tokens, v.completion_tokens, v.total_tokens, v.requests, v.last_used,
            }) catch return helpers.serverError();
        }
    }
    buf.appendSlice("]") catch return helpers.serverError();

    // by_instance
    buf.appendSlice(",\"by_instance\":[") catch return helpers.serverError();
    {
        var it = inst_map.iterator();
        var first = true;
        while (it.next()) |entry| {
            if (!first) buf.append(',') catch return helpers.serverError();
            first = false;
            const v = entry.value_ptr.*;
            buf.appendSlice("{\"component\":\"") catch return helpers.serverError();
            appendEscaped(&buf, v.component) catch return helpers.serverError();
            buf.appendSlice("\",\"name\":\"") catch return helpers.serverError();
            appendEscaped(&buf, v.name) catch return helpers.serverError();
            buf.print("\",\"prompt_tokens\":{d},\"completion_tokens\":{d},\"total_tokens\":{d},\"requests\":{d}}}", .{
                v.prompt_tokens, v.completion_tokens, v.total_tokens, v.requests,
            }) catch return helpers.serverError();
        }
    }
    buf.appendSlice("]") catch return helpers.serverError();

    // timeseries — sorted by bucket_start
    buf.appendSlice(",\"timeseries\":[") catch return helpers.serverError();
    {
        var ts_keys: std.ArrayListUnmanaged(i64) = .empty;
        defer ts_keys.deinit(allocator);
        var ts_it = ts_map.iterator();
        while (ts_it.next()) |entry| {
            ts_keys.append(allocator, entry.key_ptr.*) catch continue;
        }
        std.mem.sort(i64, ts_keys.items, {}, std.sort.asc(i64));

        for (ts_keys.items, 0..) |ts_key, idx| {
            if (idx > 0) buf.append(',') catch return helpers.serverError();
            const b = ts_map.get(ts_key) orelse continue;
            buf.print("{{\"bucket_start\":{d},\"prompt_tokens\":{d},\"completion_tokens\":{d},\"total_tokens\":{d},\"requests\":{d}}}", .{
                ts_key, b.prompt_tokens, b.completion_tokens, b.total_tokens, b.requests,
            }) catch return helpers.serverError();
        }
    }
    buf.appendSlice("]") catch return helpers.serverError();

    buf.appendSlice("}") catch return helpers.serverError();
    return helpers.jsonOk(buf.items);
}
