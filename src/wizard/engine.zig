const std = @import("std");
const manifest_mod = @import("../core/manifest.zig");

pub const WizardAnswers = std.StringHashMap([]const u8);
// For multi_select, value is comma-separated: "web,telegram,discord"

pub const ValidationError = struct {
    step_id: []const u8,
    message: []const u8,
};

/// Evaluate a step condition against the current set of wizard answers.
/// If the condition is null the step is always visible (returns true).
/// If the referenced step has not been answered yet, returns false.
pub fn evaluateCondition(condition: ?manifest_mod.StepCondition, answers: *const WizardAnswers) bool {
    const cond = condition orelse return true; // no condition = always visible

    const answer = answers.get(cond.step) orelse return false; // step not answered yet

    if (cond.equals) |expected| {
        return std.mem.eql(u8, answer, expected);
    }
    if (cond.not_equals) |unexpected| {
        return !std.mem.eql(u8, answer, unexpected);
    }
    if (cond.contains) |needle| {
        // answer is comma-separated values
        var it = std.mem.splitScalar(u8, answer, ',');
        while (it.next()) |val| {
            if (std.mem.eql(u8, val, needle)) return true;
        }
        return false;
    }
    return true;
}

/// Return the indices of wizard steps whose conditions evaluate to true
/// given the current answers.
pub fn getVisibleSteps(allocator: std.mem.Allocator, steps: []const manifest_mod.WizardStep, answers: *const WizardAnswers) ![]usize {
    var visible = std.array_list.Managed(usize).init(allocator);
    errdefer visible.deinit();
    for (steps, 0..) |step, i| {
        if (evaluateCondition(step.condition, answers)) {
            try visible.append(i);
        }
    }
    return visible.toOwnedSlice();
}

/// Validate all visible wizard steps: check that required fields have answers
/// and that select / multi_select / number values are well-formed.
pub fn validateAnswers(allocator: std.mem.Allocator, steps: []const manifest_mod.WizardStep, answers: *const WizardAnswers) ![]ValidationError {
    var errors = std.array_list.Managed(ValidationError).init(allocator);
    errdefer errors.deinit();

    for (steps) |step| {
        // Skip invisible steps
        if (!evaluateCondition(step.condition, answers)) continue;

        const answer = answers.get(step.id);

        // Check required
        if (step.required) {
            if (answer == null or answer.?.len == 0) {
                try errors.append(.{
                    .step_id = step.id,
                    .message = "required field is empty",
                });
                continue;
            }
        }

        if (answer) |val| {
            // Validate select: value must be one of the options
            if (step.@"type" == .select) {
                var found = false;
                for (step.options) |opt| {
                    if (std.mem.eql(u8, val, opt.value)) {
                        found = true;
                        break;
                    }
                }
                if (!found and step.options.len > 0) {
                    try errors.append(.{
                        .step_id = step.id,
                        .message = "invalid option selected",
                    });
                }
            }

            // Validate multi_select: each comma-separated value must be valid
            if (step.@"type" == .multi_select) {
                var it = std.mem.splitScalar(u8, val, ',');
                while (it.next()) |part| {
                    var found = false;
                    for (step.options) |opt| {
                        if (std.mem.eql(u8, part, opt.value)) {
                            found = true;
                            break;
                        }
                    }
                    if (!found and step.options.len > 0) {
                        try errors.append(.{
                            .step_id = step.id,
                            .message = "invalid option in multi-select",
                        });
                        break;
                    }
                }
            }

            // Validate number: must parse as integer
            if (step.@"type" == .number) {
                _ = std.fmt.parseInt(i64, val, 10) catch {
                    try errors.append(.{
                        .step_id = step.id,
                        .message = "must be a number",
                    });
                };
            }
        }
    }

    return errors.toOwnedSlice();
}

// ─── Tests ───────────────────────────────────────────────────────────────────

test "evaluateCondition: no condition always true" {
    var answers = WizardAnswers.init(std.testing.allocator);
    defer answers.deinit();
    try std.testing.expect(evaluateCondition(null, &answers));
}

test "evaluateCondition: equals match" {
    var answers = WizardAnswers.init(std.testing.allocator);
    defer answers.deinit();
    try answers.put("provider", "anthropic");
    try std.testing.expect(evaluateCondition(.{ .step = "provider", .equals = "anthropic" }, &answers));
}

test "evaluateCondition: equals mismatch" {
    var answers = WizardAnswers.init(std.testing.allocator);
    defer answers.deinit();
    try answers.put("provider", "openai");
    try std.testing.expect(!evaluateCondition(.{ .step = "provider", .equals = "anthropic" }, &answers));
}

test "evaluateCondition: not_equals" {
    var answers = WizardAnswers.init(std.testing.allocator);
    defer answers.deinit();
    try answers.put("provider", "anthropic");
    try std.testing.expect(evaluateCondition(.{ .step = "provider", .not_equals = "ollama" }, &answers));
}

test "evaluateCondition: contains in comma-separated" {
    var answers = WizardAnswers.init(std.testing.allocator);
    defer answers.deinit();
    try answers.put("channels", "web,telegram,discord");
    try std.testing.expect(evaluateCondition(.{ .step = "channels", .contains = "telegram" }, &answers));
    try std.testing.expect(!evaluateCondition(.{ .step = "channels", .contains = "slack" }, &answers));
}

test "evaluateCondition: missing step answer" {
    var answers = WizardAnswers.init(std.testing.allocator);
    defer answers.deinit();
    try std.testing.expect(!evaluateCondition(.{ .step = "provider", .equals = "x" }, &answers));
}

test "validateAnswers: required field missing" {
    const steps = [_]manifest_mod.WizardStep{
        .{
            .id = "name",
            .title = "Enter name",
            .@"type" = .text,
            .required = true,
            .writes_to = "name",
        },
    };

    var answers = WizardAnswers.init(std.testing.allocator);
    defer answers.deinit();

    const errors = try validateAnswers(std.testing.allocator, &steps, &answers);
    defer std.testing.allocator.free(errors);

    try std.testing.expectEqual(@as(usize, 1), errors.len);
    try std.testing.expectEqualStrings("name", errors[0].step_id);
    try std.testing.expectEqualStrings("required field is empty", errors[0].message);
}

test "validateAnswers: invalid select option" {
    const steps = [_]manifest_mod.WizardStep{
        .{
            .id = "provider",
            .title = "Select provider",
            .@"type" = .select,
            .required = true,
            .writes_to = "provider",
            .options = &.{
                .{ .value = "openai", .label = "OpenAI" },
                .{ .value = "anthropic", .label = "Anthropic" },
            },
        },
    };

    var answers = WizardAnswers.init(std.testing.allocator);
    defer answers.deinit();
    try answers.put("provider", "invalid_provider");

    const errors = try validateAnswers(std.testing.allocator, &steps, &answers);
    defer std.testing.allocator.free(errors);

    try std.testing.expectEqual(@as(usize, 1), errors.len);
    try std.testing.expectEqualStrings("provider", errors[0].step_id);
    try std.testing.expectEqualStrings("invalid option selected", errors[0].message);
}

test "validateAnswers: valid answers pass" {
    const steps = [_]manifest_mod.WizardStep{
        .{
            .id = "provider",
            .title = "Select provider",
            .@"type" = .select,
            .required = true,
            .writes_to = "provider",
            .options = &.{
                .{ .value = "openai", .label = "OpenAI" },
                .{ .value = "anthropic", .label = "Anthropic" },
            },
        },
        .{
            .id = "port",
            .title = "Port number",
            .@"type" = .number,
            .required = true,
            .writes_to = "port",
        },
    };

    var answers = WizardAnswers.init(std.testing.allocator);
    defer answers.deinit();
    try answers.put("provider", "anthropic");
    try answers.put("port", "8080");

    const errors = try validateAnswers(std.testing.allocator, &steps, &answers);
    defer std.testing.allocator.free(errors);

    try std.testing.expectEqual(@as(usize, 0), errors.len);
}

test "validateAnswers: skips invisible steps" {
    const steps = [_]manifest_mod.WizardStep{
        .{
            .id = "api_key",
            .title = "API Key",
            .@"type" = .secret,
            .required = true,
            .writes_to = "api_key",
            .condition = .{ .step = "provider", .equals = "cloud" },
        },
    };

    // provider is not answered so condition evaluates to false → step is invisible
    var answers = WizardAnswers.init(std.testing.allocator);
    defer answers.deinit();

    const errors = try validateAnswers(std.testing.allocator, &steps, &answers);
    defer std.testing.allocator.free(errors);

    try std.testing.expectEqual(@as(usize, 0), errors.len);
}

test "getVisibleSteps filters by condition" {
    const steps = [_]manifest_mod.WizardStep{
        .{
            .id = "provider",
            .title = "Select provider",
            .@"type" = .select,
            .required = true,
            .writes_to = "provider",
        },
        .{
            .id = "api_key",
            .title = "API Key",
            .@"type" = .secret,
            .required = true,
            .writes_to = "api_key",
            .condition = .{ .step = "provider", .equals = "cloud" },
        },
        .{
            .id = "model",
            .title = "Model",
            .@"type" = .text,
            .required = false,
            .writes_to = "model",
        },
    };

    var answers = WizardAnswers.init(std.testing.allocator);
    defer answers.deinit();
    try answers.put("provider", "local");

    const visible = try getVisibleSteps(std.testing.allocator, &steps, &answers);
    defer std.testing.allocator.free(visible);

    // Step 0 (no condition) and step 2 (no condition) are visible.
    // Step 1 requires provider == "cloud" but it is "local", so hidden.
    try std.testing.expectEqual(@as(usize, 2), visible.len);
    try std.testing.expectEqual(@as(usize, 0), visible[0]);
    try std.testing.expectEqual(@as(usize, 2), visible[1]);
}
