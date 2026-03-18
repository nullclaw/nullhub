const std = @import("std");

pub const ReportRepo = enum {
    nullhub,
    nullclaw,
    nullboiler,
    nulltickets,
    nullwatch,

    pub fn fromStr(s: []const u8) ?ReportRepo {
        inline for (repo_specs) |spec| {
            if (std.mem.eql(u8, s, spec.value)) return spec.id;
        }
        return null;
    }

    pub fn value(self: ReportRepo) []const u8 {
        return specForRepo(self).value;
    }

    pub fn toGithubRepo(self: ReportRepo) []const u8 {
        return specForRepo(self).github_repo;
    }

    pub fn displayName(self: ReportRepo) []const u8 {
        return specForRepo(self).display_name;
    }

    pub fn localCheckoutPath(self: ReportRepo) []const u8 {
        return specForRepo(self).local_checkout_path;
    }
};

pub const ReportType = enum {
    bug_crash,
    bug_behavior,
    regression,
    feature,

    pub fn fromStr(s: []const u8) ?ReportType {
        inline for (type_specs) |spec| {
            if (std.mem.eql(u8, s, spec.value)) return spec.id;
        }
        return null;
    }

    pub fn value(self: ReportType) []const u8 {
        return specForType(self).value;
    }

    pub fn toLabels(self: ReportType) []const []const u8 {
        return specForType(self).labels;
    }

    pub fn displayName(self: ReportType) []const u8 {
        return specForType(self).display_name;
    }

    pub fn issuePrefix(self: ReportType) []const u8 {
        return specForType(self).issue_prefix;
    }

    pub fn templateFileName(self: ReportType) []const u8 {
        return specForType(self).template_file_name;
    }
};

pub const RepoSpec = struct {
    id: ReportRepo,
    value: []const u8,
    display_name: []const u8,
    github_repo: []const u8,
    local_checkout_path: []const u8,
};

pub const TypeSpec = struct {
    id: ReportType,
    value: []const u8,
    display_name: []const u8,
    issue_prefix: []const u8,
    labels: []const []const u8,
    template_file_name: []const u8,
};

const repo_specs = [_]RepoSpec{
    .{
        .id = .nullhub,
        .value = "nullhub",
        .display_name = "NullHub",
        .github_repo = "nullclaw/nullhub",
        .local_checkout_path = "../nullhub",
    },
    .{
        .id = .nullclaw,
        .value = "nullclaw",
        .display_name = "NullClaw",
        .github_repo = "nullclaw/nullclaw",
        .local_checkout_path = "../nullclaw",
    },
    .{
        .id = .nullboiler,
        .value = "nullboiler",
        .display_name = "NullBoiler",
        .github_repo = "nullclaw/NullBoiler",
        .local_checkout_path = "../NullBoiler",
    },
    .{
        .id = .nulltickets,
        .value = "nulltickets",
        .display_name = "NullTickets",
        .github_repo = "nullclaw/nulltickets",
        .local_checkout_path = "../nulltickets",
    },
    .{
        .id = .nullwatch,
        .value = "nullwatch",
        .display_name = "NullWatch",
        .github_repo = "nullclaw/nullwatch",
        .local_checkout_path = "../nullwatch",
    },
};

const type_specs = [_]TypeSpec{
    .{
        .id = .bug_crash,
        .value = "bug:crash",
        .display_name = "Bug: crash (process exits or hangs)",
        .issue_prefix = "[Bug]",
        .labels = &.{ "bug", "bug:crash" },
        .template_file_name = "bug_report.yml",
    },
    .{
        .id = .bug_behavior,
        .value = "bug:behavior",
        .display_name = "Bug: behavior (incorrect output/state)",
        .issue_prefix = "[Bug]",
        .labels = &.{ "bug", "bug:behavior" },
        .template_file_name = "bug_report.yml",
    },
    .{
        .id = .regression,
        .value = "regression",
        .display_name = "Bug: regression (worked before, now fails)",
        .issue_prefix = "[Bug]",
        .labels = &.{ "bug", "regression" },
        .template_file_name = "bug_report.yml",
    },
    .{
        .id = .feature,
        .value = "feature",
        .display_name = "Feature request",
        .issue_prefix = "[Feature]",
        .labels = &.{"enhancement"},
        .template_file_name = "feature_request.yml",
    },
};

pub fn repos() []const RepoSpec {
    return &repo_specs;
}

pub fn types() []const TypeSpec {
    return &type_specs;
}

pub fn specForRepo(repo: ReportRepo) RepoSpec {
    inline for (repo_specs) |spec| {
        if (spec.id == repo) return spec;
    }
    unreachable;
}

pub fn specForType(report_type: ReportType) TypeSpec {
    inline for (type_specs) |spec| {
        if (spec.id == report_type) return spec;
    }
    unreachable;
}

pub fn localTemplatePathAlloc(
    allocator: std.mem.Allocator,
    repo: ReportRepo,
    report_type: ReportType,
) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/.github/ISSUE_TEMPLATE/{s}", .{
        repo.localCheckoutPath(),
        report_type.templateFileName(),
    });
}

pub fn remoteTemplateUrlAlloc(
    allocator: std.mem.Allocator,
    repo: ReportRepo,
    report_type: ReportType,
) ![]u8 {
    return std.fmt.allocPrint(allocator, "https://raw.githubusercontent.com/{s}/main/.github/ISSUE_TEMPLATE/{s}", .{
        repo.toGithubRepo(),
        report_type.templateFileName(),
    });
}

test "repo order is stable" {
    try std.testing.expectEqualStrings("nullhub", repos()[0].value);
    try std.testing.expectEqualStrings("nullclaw", repos()[1].value);
    try std.testing.expectEqualStrings("nullboiler", repos()[2].value);
    try std.testing.expectEqualStrings("nulltickets", repos()[3].value);
    try std.testing.expectEqualStrings("nullwatch", repos()[4].value);
}

test "type labels stay wired" {
    const crash = ReportType.bug_crash.toLabels();
    try std.testing.expectEqualStrings("bug", crash[0]);
    try std.testing.expectEqualStrings("bug:crash", crash[1]);
    try std.testing.expectEqualStrings("feature_request.yml", ReportType.feature.templateFileName());
}
