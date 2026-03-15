const std = @import("std");
const helpers = @import("helpers.zig");

pub const ParamSpec = struct {
    name: []const u8,
    location: []const u8,
    required: bool,
    description: []const u8,
};

pub const ExampleSpec = struct {
    command: []const u8,
    description: []const u8,
};

pub const RouteSpec = struct {
    id: []const u8,
    method: []const u8,
    path_template: []const u8,
    category: []const u8,
    summary: []const u8,
    destructive: bool = false,
    auth_required: bool = false,
    auth_mode: []const u8 = "optional_bearer",
    path_params: []const ParamSpec = &.{},
    query_params: []const ParamSpec = &.{},
    body: ?[]const u8 = null,
    response: ?[]const u8 = null,
    examples: []const ExampleSpec = &.{},
};

const Document = struct {
    version: u32,
    routes: []const RouteSpec,
};

const component_param = ParamSpec{
    .name = "component",
    .location = "path",
    .required = true,
    .description = "Component name such as nullclaw, nullhub, nullboiler, or nulltickets.",
};

const instance_name_param = ParamSpec{
    .name = "name",
    .location = "path",
    .required = true,
    .description = "Instance name within the component namespace.",
};

const module_name_param = ParamSpec{
    .name = "module",
    .location = "path",
    .required = true,
    .description = "UI module name.",
};

const component_name_param = ParamSpec{
    .name = "name",
    .location = "path",
    .required = true,
    .description = "Component name.",
};

const wizard_component_param = ParamSpec{
    .name = "component",
    .location = "path",
    .required = true,
    .description = "Component to inspect or configure through the setup wizard.",
};

const provider_id_param = ParamSpec{
    .name = "id",
    .location = "path",
    .required = true,
    .description = "Saved provider numeric identifier.",
};

const channel_id_param = ParamSpec{
    .name = "id",
    .location = "path",
    .required = true,
    .description = "Saved channel numeric identifier.",
};

const window_query = ParamSpec{
    .name = "window",
    .location = "query",
    .required = false,
    .description = "Usage window such as 24h, 7d, 30d, or all.",
};

const reveal_query = ParamSpec{
    .name = "reveal",
    .location = "query",
    .required = false,
    .description = "When true, include secret-like fields in the response for local admin usage.",
};

const lines_query = ParamSpec{
    .name = "lines",
    .location = "query",
    .required = false,
    .description = "How many log lines to return. Defaults to 100.",
};

const log_source_query = ParamSpec{
    .name = "source",
    .location = "query",
    .required = false,
    .description = "Log source selector: instance or nullhub.",
};

const history_limit_query = ParamSpec{
    .name = "limit",
    .location = "query",
    .required = false,
    .description = "Maximum number of history entries to return.",
};

const history_offset_query = ParamSpec{
    .name = "offset",
    .location = "query",
    .required = false,
    .description = "History pagination offset.",
};

const history_session_query = ParamSpec{
    .name = "session_id",
    .location = "query",
    .required = false,
    .description = "Optional nullclaw session identifier to scope history.",
};

const memory_stats_query = ParamSpec{
    .name = "stats",
    .location = "query",
    .required = false,
    .description = "When set, returns memory stats instead of entries.",
};

const memory_key_query = ParamSpec{
    .name = "key",
    .location = "query",
    .required = false,
    .description = "Fetch a single memory record by key.",
};

const memory_query_query = ParamSpec{
    .name = "query",
    .location = "query",
    .required = false,
    .description = "Keyword search query for instance memory.",
};

const memory_category_query = ParamSpec{
    .name = "category",
    .location = "query",
    .required = false,
    .description = "Category filter for memory listing.",
};

const memory_limit_query = ParamSpec{
    .name = "limit",
    .location = "query",
    .required = false,
    .description = "Maximum number of memory results.",
};

const skill_name_query = ParamSpec{
    .name = "name",
    .location = "query",
    .required = false,
    .description = "Optional skill name filter.",
};

const skill_catalog_query = ParamSpec{
    .name = "catalog",
    .location = "query",
    .required = false,
    .description = "When true, return the recommended skill catalog instead of installed skills.",
};

const common_instance_params = [_]ParamSpec{ component_param, instance_name_param };
const component_only_params = [_]ParamSpec{component_param};
const provider_id_params = [_]ParamSpec{provider_id_param};
const channel_id_params = [_]ParamSpec{channel_id_param};
const module_name_params = [_]ParamSpec{module_name_param};
const component_name_params = [_]ParamSpec{component_name_param};
const wizard_component_params = [_]ParamSpec{wizard_component_param};
const usage_query_params = [_]ParamSpec{window_query};
const reveal_query_params = [_]ParamSpec{reveal_query};
const logs_query_params = [_]ParamSpec{ lines_query, log_source_query };
const history_query_params = [_]ParamSpec{ history_session_query, history_limit_query, history_offset_query };
const memory_query_params = [_]ParamSpec{ memory_stats_query, memory_key_query, memory_query_query, memory_category_query, memory_limit_query };
const skills_query_params = [_]ParamSpec{ skill_name_query, skill_catalog_query };

const route_examples_status = [_]ExampleSpec{
    .{
        .command = "nullhub api GET /api/status --pretty",
        .description = "Inspect hub health, uptime, and instance summary.",
    },
};

const route_examples_instances = [_]ExampleSpec{
    .{
        .command = "nullhub api GET /api/instances --pretty",
        .description = "List all managed instances.",
    },
};

const route_examples_delete_instance = [_]ExampleSpec{
    .{
        .command = "nullhub api DELETE /api/instances/nullclaw/instance-2",
        .description = "Delete a managed nullclaw instance and let nullhub clean related state.",
    },
};

const route_examples_provider_validate = [_]ExampleSpec{
    .{
        .command = "nullhub api POST /api/providers/2/validate",
        .description = "Run a live provider credential probe.",
    },
};

const route_examples_skill_catalog = [_]ExampleSpec{
    .{
        .command = "nullhub api GET '/api/instances/nullclaw/instance-1/skills?catalog=1' --pretty",
        .description = "Inspect the recommended skill catalog for a managed nullclaw instance.",
    },
};

const route_examples_skill_install = [_]ExampleSpec{
    .{
        .command = "nullhub api POST /api/instances/nullclaw/instance-1/skills --body '{\"bundled\":\"nullhub-admin\"}'",
        .description = "Install the bundled nullhub-admin skill into a managed nullclaw workspace.",
    },
    .{
        .command = "nullhub api POST /api/instances/nullclaw/instance-1/skills --body '{\"clawhub_slug\":\"my-skill\"}'",
        .description = "Install a skill from ClawHub when the host has the clawhub CLI available.",
    },
};

const route_examples_skill_remove = [_]ExampleSpec{
    .{
        .command = "nullhub api DELETE '/api/instances/nullclaw/instance-1/skills?name=nullhub-admin'",
        .description = "Remove a workspace-installed skill from a managed nullclaw instance.",
    },
};

const route_examples_meta = [_]ExampleSpec{
    .{
        .command = "nullhub routes --json",
        .description = "Inspect the machine-readable route catalog locally without a running server.",
    },
    .{
        .command = "nullhub api GET /api/meta/routes --pretty",
        .description = "Fetch the same route catalog over HTTP.",
    },
};

const routes = [_]RouteSpec{
    .{
        .id = "health",
        .method = "GET",
        .path_template = "/health",
        .category = "meta",
        .summary = "Lightweight liveness probe for load balancers and local checks.",
        .auth_mode = "public",
        .response = "Returns {\"status\":\"ok\"}.",
    },
    .{
        .id = "status.get",
        .method = "GET",
        .path_template = "/api/status",
        .category = "meta",
        .summary = "Hub status, access URLs, and live instance overview.",
        .auth_mode = "optional_bearer",
        .response = "Aggregated status document used by the dashboard.",
        .examples = route_examples_status[0..],
    },
    .{
        .id = "meta.routes.get",
        .method = "GET",
        .path_template = "/api/meta/routes",
        .category = "meta",
        .summary = "Machine-readable catalog of stable nullhub HTTP routes.",
        .auth_mode = "optional_bearer",
        .response = "JSON document with route ids, methods, paths, parameters, and examples.",
        .examples = route_examples_meta[0..],
    },
    .{
        .id = "components.list",
        .method = "GET",
        .path_template = "/api/components",
        .category = "components",
        .summary = "List known ecosystem components and installation state.",
        .auth_mode = "optional_bearer",
        .response = "Component array with installed/version metadata.",
    },
    .{
        .id = "components.manifest.get",
        .method = "GET",
        .path_template = "/api/components/{name}/manifest",
        .category = "components",
        .summary = "Return cached component manifest JSON if available.",
        .auth_mode = "optional_bearer",
        .path_params = component_name_params[0..],
        .response = "Manifest JSON exported by the component binary.",
    },
    .{
        .id = "components.refresh",
        .method = "POST",
        .path_template = "/api/components/refresh",
        .category = "components",
        .summary = "Refresh the component registry and cached manifests.",
        .auth_mode = "optional_bearer",
        .response = "Refresh status payload.",
    },
    .{
        .id = "wizard.free_port",
        .method = "GET",
        .path_template = "/api/free-port",
        .category = "wizard",
        .summary = "Find an available local TCP port during setup flows.",
        .auth_mode = "optional_bearer",
        .response = "Returns {\"port\":<number>}.",
    },
    .{
        .id = "usage.global.get",
        .method = "GET",
        .path_template = "/api/usage",
        .category = "usage",
        .summary = "Aggregate usage across the whole hub.",
        .auth_mode = "optional_bearer",
        .query_params = usage_query_params[0..],
        .response = "Cross-instance usage summary.",
    },
    .{
        .id = "settings.get",
        .method = "GET",
        .path_template = "/api/settings",
        .category = "settings",
        .summary = "Read hub settings and published access URLs.",
        .auth_mode = "optional_bearer",
        .response = "Current nullhub settings document.",
    },
    .{
        .id = "settings.put",
        .method = "PUT",
        .path_template = "/api/settings",
        .category = "settings",
        .summary = "Update hub settings such as port or access behavior.",
        .auth_mode = "optional_bearer",
        .body = "Settings JSON payload.",
        .response = "Saved settings payload.",
    },
    .{
        .id = "service.install",
        .method = "POST",
        .path_template = "/api/service/install",
        .category = "settings",
        .summary = "Install nullhub as an OS service.",
        .auth_mode = "optional_bearer",
        .response = "Platform-specific install result.",
    },
    .{
        .id = "service.uninstall",
        .method = "POST",
        .path_template = "/api/service/uninstall",
        .category = "settings",
        .summary = "Remove the OS service installation for nullhub.",
        .auth_mode = "optional_bearer",
        .destructive = true,
        .response = "Service uninstall result.",
    },
    .{
        .id = "service.status",
        .method = "GET",
        .path_template = "/api/service/status",
        .category = "settings",
        .summary = "Inspect whether the OS service is installed and running.",
        .auth_mode = "optional_bearer",
        .response = "Service status payload.",
    },
    .{
        .id = "updates.list",
        .method = "GET",
        .path_template = "/api/updates",
        .category = "updates",
        .summary = "List available component updates.",
        .auth_mode = "optional_bearer",
        .response = "Pending update list.",
    },
    .{
        .id = "ui_modules.list",
        .method = "GET",
        .path_template = "/api/ui-modules",
        .category = "ui",
        .summary = "List installed UI modules and selected versions.",
        .auth_mode = "optional_bearer",
        .response = "Map of UI module names to selected versions.",
    },
    .{
        .id = "ui_modules.available",
        .method = "GET",
        .path_template = "/api/ui-modules/available",
        .category = "ui",
        .summary = "List UI modules available from known component sources.",
        .auth_mode = "optional_bearer",
        .response = "Available UI module records.",
    },
    .{
        .id = "ui_modules.install",
        .method = "POST",
        .path_template = "/api/ui-modules/{module}/install",
        .category = "ui",
        .summary = "Install or refresh a UI module.",
        .auth_mode = "optional_bearer",
        .path_params = module_name_params[0..],
        .response = "Install status payload.",
    },
    .{
        .id = "ui_modules.delete",
        .method = "DELETE",
        .path_template = "/api/ui-modules/{module}",
        .category = "ui",
        .summary = "Uninstall a UI module.",
        .auth_mode = "optional_bearer",
        .path_params = module_name_params[0..],
        .destructive = true,
        .response = "Delete status payload.",
    },
    .{
        .id = "wizard.get",
        .method = "GET",
        .path_template = "/api/wizard/{component}",
        .category = "wizard",
        .summary = "Fetch wizard metadata and defaults for a component.",
        .auth_mode = "optional_bearer",
        .path_params = wizard_component_params[0..],
        .response = "Wizard definition JSON.",
    },
    .{
        .id = "wizard.post",
        .method = "POST",
        .path_template = "/api/wizard/{component}",
        .category = "wizard",
        .summary = "Create or update a component instance from wizard form data.",
        .auth_mode = "optional_bearer",
        .path_params = wizard_component_params[0..],
        .body = "Wizard submission JSON.",
        .response = "Created instance payload or validation error.",
    },
    .{
        .id = "wizard.versions.get",
        .method = "GET",
        .path_template = "/api/wizard/{component}/versions",
        .category = "wizard",
        .summary = "List installable versions for a component.",
        .auth_mode = "optional_bearer",
        .path_params = wizard_component_params[0..],
        .response = "Version options for installer flows.",
    },
    .{
        .id = "wizard.models.get",
        .method = "GET",
        .path_template = "/api/wizard/{component}/models",
        .category = "wizard",
        .summary = "List model options for a component/provider pairing.",
        .auth_mode = "optional_bearer",
        .path_params = wizard_component_params[0..],
        .response = "Model list payload.",
    },
    .{
        .id = "wizard.models.post",
        .method = "POST",
        .path_template = "/api/wizard/{component}/models",
        .category = "wizard",
        .summary = "Resolve model options from posted credentials or provider selection.",
        .auth_mode = "optional_bearer",
        .path_params = wizard_component_params[0..],
        .body = "Provider/model discovery request JSON.",
        .response = "Model list payload or validation error.",
    },
    .{
        .id = "wizard.validate_providers",
        .method = "POST",
        .path_template = "/api/wizard/{component}/validate-providers",
        .category = "wizard",
        .summary = "Validate provider credentials during setup.",
        .auth_mode = "optional_bearer",
        .path_params = wizard_component_params[0..],
        .body = "Provider validation request JSON.",
        .response = "Validation result array.",
    },
    .{
        .id = "wizard.validate_channels",
        .method = "POST",
        .path_template = "/api/wizard/{component}/validate-channels",
        .category = "wizard",
        .summary = "Validate channel credentials during setup.",
        .auth_mode = "optional_bearer",
        .path_params = wizard_component_params[0..],
        .body = "Channel validation request JSON.",
        .response = "Validation result array.",
    },
    .{
        .id = "providers.list",
        .method = "GET",
        .path_template = "/api/providers",
        .category = "providers",
        .summary = "List saved providers.",
        .auth_mode = "optional_bearer",
        .query_params = reveal_query_params[0..],
        .response = "Saved provider list.",
    },
    .{
        .id = "providers.create",
        .method = "POST",
        .path_template = "/api/providers",
        .category = "providers",
        .summary = "Create a saved provider entry.",
        .auth_mode = "optional_bearer",
        .body = "Provider create payload.",
        .response = "Created provider record.",
    },
    .{
        .id = "providers.update",
        .method = "PUT",
        .path_template = "/api/providers/{id}",
        .category = "providers",
        .summary = "Update a saved provider entry.",
        .auth_mode = "optional_bearer",
        .path_params = provider_id_params[0..],
        .body = "Provider update payload.",
        .response = "Updated provider record.",
    },
    .{
        .id = "providers.delete",
        .method = "DELETE",
        .path_template = "/api/providers/{id}",
        .category = "providers",
        .summary = "Delete a saved provider entry.",
        .auth_mode = "optional_bearer",
        .path_params = provider_id_params[0..],
        .destructive = true,
        .response = "Delete status payload.",
    },
    .{
        .id = "providers.validate",
        .method = "POST",
        .path_template = "/api/providers/{id}/validate",
        .category = "providers",
        .summary = "Run a live provider probe using the saved config.",
        .auth_mode = "optional_bearer",
        .path_params = provider_id_params[0..],
        .response = "Provider validation result.",
        .examples = route_examples_provider_validate[0..],
    },
    .{
        .id = "channels.list",
        .method = "GET",
        .path_template = "/api/channels",
        .category = "channels",
        .summary = "List saved channels.",
        .auth_mode = "optional_bearer",
        .query_params = reveal_query_params[0..],
        .response = "Saved channel list.",
    },
    .{
        .id = "channels.create",
        .method = "POST",
        .path_template = "/api/channels",
        .category = "channels",
        .summary = "Create a saved channel entry.",
        .auth_mode = "optional_bearer",
        .body = "Channel create payload.",
        .response = "Created channel record.",
    },
    .{
        .id = "channels.update",
        .method = "PUT",
        .path_template = "/api/channels/{id}",
        .category = "channels",
        .summary = "Update a saved channel entry.",
        .auth_mode = "optional_bearer",
        .path_params = channel_id_params[0..],
        .body = "Channel update payload.",
        .response = "Updated channel record.",
    },
    .{
        .id = "channels.delete",
        .method = "DELETE",
        .path_template = "/api/channels/{id}",
        .category = "channels",
        .summary = "Delete a saved channel entry.",
        .auth_mode = "optional_bearer",
        .path_params = channel_id_params[0..],
        .destructive = true,
        .response = "Delete status payload.",
    },
    .{
        .id = "channels.validate",
        .method = "POST",
        .path_template = "/api/channels/{id}/validate",
        .category = "channels",
        .summary = "Run a live channel probe using the saved config.",
        .auth_mode = "optional_bearer",
        .path_params = channel_id_params[0..],
        .response = "Channel validation result.",
    },
    .{
        .id = "instances.list",
        .method = "GET",
        .path_template = "/api/instances",
        .category = "instances",
        .summary = "List all managed instances across components.",
        .auth_mode = "optional_bearer",
        .response = "Instance collection grouped by component.",
        .examples = route_examples_instances[0..],
    },
    .{
        .id = "instances.get",
        .method = "GET",
        .path_template = "/api/instances/{component}/{name}",
        .category = "instances",
        .summary = "Read a single instance detail record.",
        .auth_mode = "optional_bearer",
        .path_params = common_instance_params[0..],
        .response = "Instance detail payload.",
    },
    .{
        .id = "instances.patch",
        .method = "PATCH",
        .path_template = "/api/instances/{component}/{name}",
        .category = "instances",
        .summary = "Update instance launch metadata such as auto_start or verbose mode.",
        .auth_mode = "optional_bearer",
        .path_params = common_instance_params[0..],
        .body = "Partial instance settings JSON.",
        .response = "Updated instance status payload.",
    },
    .{
        .id = "instances.delete",
        .method = "DELETE",
        .path_template = "/api/instances/{component}/{name}",
        .category = "instances",
        .summary = "Delete an instance and let nullhub clean its managed files.",
        .auth_mode = "optional_bearer",
        .path_params = common_instance_params[0..],
        .destructive = true,
        .response = "Delete status payload.",
        .examples = route_examples_delete_instance[0..],
    },
    .{
        .id = "instances.start",
        .method = "POST",
        .path_template = "/api/instances/{component}/{name}/start",
        .category = "instances",
        .summary = "Start an instance process.",
        .auth_mode = "optional_bearer",
        .path_params = common_instance_params[0..],
        .body = "Optional launch overrides such as launch_mode or verbose.",
        .response = "Start status payload.",
    },
    .{
        .id = "instances.stop",
        .method = "POST",
        .path_template = "/api/instances/{component}/{name}/stop",
        .category = "instances",
        .summary = "Stop an instance process.",
        .auth_mode = "optional_bearer",
        .path_params = common_instance_params[0..],
        .response = "Stop status payload.",
    },
    .{
        .id = "instances.restart",
        .method = "POST",
        .path_template = "/api/instances/{component}/{name}/restart",
        .category = "instances",
        .summary = "Restart an instance process.",
        .auth_mode = "optional_bearer",
        .path_params = common_instance_params[0..],
        .body = "Optional launch overrides such as launch_mode or verbose.",
        .response = "Restart status payload.",
    },
    .{
        .id = "instances.provider_health",
        .method = "GET",
        .path_template = "/api/instances/{component}/{name}/provider-health",
        .category = "instances",
        .summary = "Probe the live provider config of an instance.",
        .auth_mode = "optional_bearer",
        .path_params = common_instance_params[0..],
        .response = "Provider probe result.",
    },
    .{
        .id = "instances.usage",
        .method = "GET",
        .path_template = "/api/instances/{component}/{name}/usage",
        .category = "instances",
        .summary = "Read per-instance usage aggregates.",
        .auth_mode = "optional_bearer",
        .path_params = common_instance_params[0..],
        .query_params = usage_query_params[0..],
        .response = "Instance usage payload.",
    },
    .{
        .id = "instances.history",
        .method = "GET",
        .path_template = "/api/instances/{component}/{name}/history",
        .category = "instances",
        .summary = "Read persisted conversation history for an instance.",
        .auth_mode = "optional_bearer",
        .path_params = common_instance_params[0..],
        .query_params = history_query_params[0..],
        .response = "Paginated history payload.",
    },
    .{
        .id = "instances.onboarding",
        .method = "GET",
        .path_template = "/api/instances/{component}/{name}/onboarding",
        .category = "instances",
        .summary = "Read onboarding/bootstrap status for an instance.",
        .auth_mode = "optional_bearer",
        .path_params = common_instance_params[0..],
        .response = "Onboarding status payload.",
    },
    .{
        .id = "instances.memory",
        .method = "GET",
        .path_template = "/api/instances/{component}/{name}/memory",
        .category = "instances",
        .summary = "Inspect instance memory stats, records, or searches.",
        .auth_mode = "optional_bearer",
        .path_params = common_instance_params[0..],
        .query_params = memory_query_params[0..],
        .response = "Memory stats or memory entry list depending on query mode.",
    },
    .{
        .id = "instances.skills",
        .method = "GET",
        .path_template = "/api/instances/{component}/{name}/skills",
        .category = "instances",
        .summary = "List installed skills for an instance.",
        .auth_mode = "optional_bearer",
        .path_params = common_instance_params[0..],
        .query_params = skills_query_params[0..],
        .response = "Skill list or single skill detail.",
    },
    .{
        .id = "instances.skills.catalog",
        .method = "GET",
        .path_template = "/api/instances/{component}/{name}/skills?catalog=1",
        .category = "instances",
        .summary = "List recommended managed skills for the instance component.",
        .auth_mode = "optional_bearer",
        .path_params = common_instance_params[0..],
        .query_params = skills_query_params[0..],
        .response = "Recommended skill catalog entries.",
        .examples = route_examples_skill_catalog[0..],
    },
    .{
        .id = "instances.skills.install",
        .method = "POST",
        .path_template = "/api/instances/{component}/{name}/skills",
        .category = "instances",
        .summary = "Install a skill into a managed nullclaw workspace from a bundled skill, ClawHub slug, or source URL/path.",
        .auth_mode = "optional_bearer",
        .path_params = common_instance_params[0..],
        .body = "JSON body with exactly one of bundled, clawhub_slug, or source.",
        .response = "Install result payload.",
        .examples = route_examples_skill_install[0..],
    },
    .{
        .id = "instances.skills.remove",
        .method = "DELETE",
        .path_template = "/api/instances/{component}/{name}/skills",
        .category = "instances",
        .summary = "Remove a workspace-installed skill from a managed nullclaw instance.",
        .auth_mode = "optional_bearer",
        .path_params = common_instance_params[0..],
        .query_params = skills_query_params[0..],
        .body = null,
        .response = "Remove result payload.",
        .examples = route_examples_skill_remove[0..],
    },
    .{
        .id = "instances.integration.get",
        .method = "GET",
        .path_template = "/api/instances/{component}/{name}/integration",
        .category = "instances",
        .summary = "Read integration status for linked orchestration and tracker components.",
        .auth_mode = "optional_bearer",
        .path_params = common_instance_params[0..],
        .response = "Integration status and linkage payload.",
    },
    .{
        .id = "instances.integration.post",
        .method = "POST",
        .path_template = "/api/instances/{component}/{name}/integration",
        .category = "instances",
        .summary = "Link or relink supported components such as nullboiler and nulltickets.",
        .auth_mode = "optional_bearer",
        .path_params = common_instance_params[0..],
        .body = "Integration update payload.",
        .response = "Integration update result.",
    },
    .{
        .id = "instances.import",
        .method = "POST",
        .path_template = "/api/instances/{component}/import",
        .category = "instances",
        .summary = "Import a standalone installation into nullhub management.",
        .auth_mode = "optional_bearer",
        .path_params = component_only_params[0..],
        .response = "Imported instance payload.",
    },
    .{
        .id = "instances.config.get",
        .method = "GET",
        .path_template = "/api/instances/{component}/{name}/config",
        .category = "instances",
        .summary = "Read the raw instance config.json managed by nullhub.",
        .auth_mode = "optional_bearer",
        .path_params = common_instance_params[0..],
        .response = "Raw instance config JSON.",
    },
    .{
        .id = "instances.config.put",
        .method = "PUT",
        .path_template = "/api/instances/{component}/{name}/config",
        .category = "instances",
        .summary = "Replace the raw instance config.json managed by nullhub.",
        .auth_mode = "optional_bearer",
        .path_params = common_instance_params[0..],
        .body = "Complete config.json replacement body.",
        .response = "Save status payload.",
    },
    .{
        .id = "instances.config.patch",
        .method = "PATCH",
        .path_template = "/api/instances/{component}/{name}/config",
        .category = "instances",
        .summary = "Patch the raw instance config.json. Currently treated the same as PUT.",
        .auth_mode = "optional_bearer",
        .path_params = common_instance_params[0..],
        .body = "Complete config.json replacement body.",
        .response = "Save status payload.",
    },
    .{
        .id = "instances.logs.get",
        .method = "GET",
        .path_template = "/api/instances/{component}/{name}/logs",
        .category = "instances",
        .summary = "Read the log tail for an instance or its nullhub supervisor log.",
        .auth_mode = "optional_bearer",
        .path_params = common_instance_params[0..],
        .query_params = logs_query_params[0..],
        .response = "Log tail payload.",
    },
    .{
        .id = "instances.logs.delete",
        .method = "DELETE",
        .path_template = "/api/instances/{component}/{name}/logs",
        .category = "instances",
        .summary = "Clear stored log files for an instance or its nullhub supervisor log.",
        .auth_mode = "optional_bearer",
        .path_params = common_instance_params[0..],
        .query_params = logs_query_params[0..],
        .destructive = true,
        .response = "Delete status payload.",
    },
    .{
        .id = "instances.logs.stream",
        .method = "GET",
        .path_template = "/api/instances/{component}/{name}/logs/stream",
        .category = "instances",
        .summary = "Snapshot current log tail in a stream-shaped response.",
        .auth_mode = "optional_bearer",
        .path_params = common_instance_params[0..],
        .query_params = logs_query_params[0..],
        .response = "Log stream payload.",
    },
    .{
        .id = "instances.update",
        .method = "POST",
        .path_template = "/api/instances/{component}/{name}/update",
        .category = "instances",
        .summary = "Apply an available update to a managed instance.",
        .auth_mode = "optional_bearer",
        .path_params = common_instance_params[0..],
        .response = "Update result payload.",
    },
    .{
        .id = "orchestration.proxy",
        .method = "ANY",
        .path_template = "/api/orchestration/{...}",
        .category = "orchestration",
        .summary = "Proxy orchestration requests to NullBoiler, or store requests to NullTickets.",
        .auth_mode = "optional_bearer",
        .body = "Forwarded as-is to the orchestration backend.",
        .response = "Forwarded upstream JSON response.",
    },
};

pub fn allRoutes() []const RouteSpec {
    return routes[0..];
}

pub fn isRoutesPath(target: []const u8) bool {
    return std.mem.eql(u8, target, "/api/meta/routes") or std.mem.startsWith(u8, target, "/api/meta/routes?");
}

pub fn jsonAlloc(allocator: std.mem.Allocator) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, Document{
        .version = 1,
        .routes = allRoutes(),
    }, .{
        .whitespace = .indent_2,
        .emit_null_optional_fields = false,
    });
}

pub fn textAlloc(allocator: std.mem.Allocator) ![]u8 {
    var buf = std.array_list.Managed(u8).init(allocator);
    errdefer buf.deinit();

    const writer = buf.writer();
    try writer.print("nullhub routes ({d})\n", .{routes.len});

    var current_category: ?[]const u8 = null;
    for (allRoutes()) |route| {
        if (current_category == null or !std.mem.eql(u8, current_category.?, route.category)) {
            current_category = route.category;
            try writer.print("\n[{s}]\n", .{route.category});
        }

        try writer.print("{s: >6} {s}", .{ route.method, route.path_template });
        if (route.destructive) {
            try buf.appendSlice("  [destructive]");
        }
        try buf.appendSlice("\n");
        try writer.print("  {s}\n", .{route.summary});

        if (route.query_params.len > 0) {
            try buf.appendSlice("  query:");
            for (route.query_params, 0..) |param, index| {
                if (index > 0) try buf.appendSlice(",");
                try writer.print(" {s}", .{param.name});
            }
            try buf.appendSlice("\n");
        }
    }

    return buf.toOwnedSlice();
}

pub fn handleRoutes(allocator: std.mem.Allocator) helpers.ApiResponse {
    const body = jsonAlloc(allocator) catch return helpers.serverError();
    return helpers.jsonOk(body);
}

test "jsonAlloc includes stable route metadata" {
    const json = try jsonAlloc(std.testing.allocator);
    defer std.testing.allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"id\": \"meta.routes.get\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "/api/instances/{component}/{name}") != null);
}

test "textAlloc renders grouped route list" {
    const text = try textAlloc(std.testing.allocator);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "[meta]") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "GET /api/meta/routes") != null);
}

test "isRoutesPath matches meta routes endpoint" {
    try std.testing.expect(isRoutesPath("/api/meta/routes"));
    try std.testing.expect(isRoutesPath("/api/meta/routes?format=json"));
    try std.testing.expect(!isRoutesPath("/api/status"));
}
