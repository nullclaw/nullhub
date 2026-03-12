export type FieldType = 'text' | 'password' | 'number' | 'toggle' | 'select' | 'list';

export interface FieldDef {
  key: string;
  label: string;
  type: FieldType;
  default?: any;
  options?: string[];
  step?: number;
  min?: number;
  max?: number;
  hint?: string;
  advanced?: boolean;
}

export interface ChannelSchema {
  label: string;
  hasAccounts: boolean;
  fields: FieldDef[];
}

export const channelSchemas: Record<string, ChannelSchema> = {
  cli: {
    label: 'CLI',
    hasAccounts: false,
    fields: []
  },
  telegram: {
    label: 'Telegram',
    hasAccounts: true,
    fields: [
      { key: 'bot_token', label: 'Bot Token', type: 'password' },
      { key: 'allow_from', label: 'Allow From', type: 'list', default: [], hint: 'User IDs or * for all' },
      { key: 'group_allow_from', label: 'Group Allow From', type: 'list', default: [], advanced: true },
      { key: 'group_policy', label: 'Group Policy', type: 'select', options: ['allowlist', 'open', 'mention_only'], default: 'allowlist', advanced: true },
      { key: 'reply_in_private', label: 'Reply in Private', type: 'toggle', default: true, advanced: true },
      { key: 'require_mention', label: 'Require Mention', type: 'toggle', default: false, advanced: true },
      { key: 'proxy', label: 'Proxy', type: 'text', hint: 'e.g. socks5://host:port', advanced: true },
      { key: 'interactive.enabled', label: 'Interactive Buttons', type: 'toggle', default: false, advanced: true },
      { key: 'interactive.ttl_secs', label: 'Interactive TTL (secs)', type: 'number', default: 900, advanced: true },
      { key: 'interactive.owner_only', label: 'Interactive Owner Only', type: 'toggle', default: true, advanced: true },
      { key: 'interactive.remove_on_click', label: 'Remove on Click', type: 'toggle', default: true, advanced: true },
    ]
  },
  discord: {
    label: 'Discord',
    hasAccounts: true,
    fields: [
      { key: 'token', label: 'Bot Token', type: 'password' },
      { key: 'guild_id', label: 'Guild ID', type: 'text' },
      { key: 'allow_bots', label: 'Allow Bots', type: 'toggle', default: false },
      { key: 'allow_from', label: 'Allow From', type: 'list', default: [] },
      { key: 'require_mention', label: 'Require Mention', type: 'toggle', default: false },
    ]
  },
  slack: {
    label: 'Slack',
    hasAccounts: true,
    fields: [
      { key: 'mode', label: 'Mode', type: 'select', options: ['socket', 'http'], default: 'socket' },
      { key: 'bot_token', label: 'Bot Token', type: 'password' },
      { key: 'app_token', label: 'App Token', type: 'password' },
      { key: 'signing_secret', label: 'Signing Secret', type: 'password' },
      { key: 'webhook_path', label: 'Webhook Path', type: 'text', default: '/slack/events' },
      { key: 'channel_id', label: 'Channel ID', type: 'text' },
      { key: 'allow_from', label: 'Allow From', type: 'list', default: [] },
      { key: 'dm_policy', label: 'DM Policy', type: 'select', options: ['pairing', 'allow', 'deny', 'allowlist'], default: 'pairing' },
      { key: 'group_policy', label: 'Group Policy', type: 'select', options: ['mention_only', 'allowlist', 'open'], default: 'mention_only' },
    ]
  },
  whatsapp: {
    label: 'WhatsApp',
    hasAccounts: true,
    fields: [
      { key: 'access_token', label: 'Access Token', type: 'password' },
      { key: 'phone_number_id', label: 'Phone Number ID', type: 'text' },
      { key: 'verify_token', label: 'Verify Token', type: 'password' },
      { key: 'app_secret', label: 'App Secret', type: 'password' },
      { key: 'allow_from', label: 'Allow From', type: 'list', default: [] },
      { key: 'group_allow_from', label: 'Group Allow From', type: 'list', default: [] },
      { key: 'groups', label: 'Groups', type: 'list', default: [] },
      { key: 'group_policy', label: 'Group Policy', type: 'select', options: ['allowlist', 'open'], default: 'allowlist' },
    ]
  },
  matrix: {
    label: 'Matrix',
    hasAccounts: true,
    fields: [
      { key: 'homeserver', label: 'Homeserver URL', type: 'text' },
      { key: 'access_token', label: 'Access Token', type: 'password' },
      { key: 'room_id', label: 'Room ID', type: 'text' },
      { key: 'user_id', label: 'User ID', type: 'text' },
      { key: 'allow_from', label: 'Allow From', type: 'list', default: [] },
      { key: 'group_allow_from', label: 'Group Allow From', type: 'list', default: [] },
      { key: 'group_policy', label: 'Group Policy', type: 'select', options: ['allowlist', 'open'], default: 'allowlist' },
    ]
  },
  mattermost: {
    label: 'Mattermost',
    hasAccounts: true,
    fields: [
      { key: 'bot_token', label: 'Bot Token', type: 'password' },
      { key: 'base_url', label: 'Base URL', type: 'text' },
      { key: 'allow_from', label: 'Allow From', type: 'list', default: [] },
      { key: 'group_allow_from', label: 'Group Allow From', type: 'list', default: [] },
      { key: 'dm_policy', label: 'DM Policy', type: 'select', options: ['allowlist', 'allow', 'deny'], default: 'allowlist' },
      { key: 'group_policy', label: 'Group Policy', type: 'select', options: ['allowlist', 'open', 'mention_only'], default: 'allowlist' },
      { key: 'chatmode', label: 'Chat Mode', type: 'select', options: ['oncall', 'always'], default: 'oncall' },
      { key: 'require_mention', label: 'Require Mention', type: 'toggle', default: true },
    ]
  },
  irc: {
    label: 'IRC',
    hasAccounts: true,
    fields: [
      { key: 'host', label: 'Host', type: 'text' },
      { key: 'port', label: 'Port', type: 'number', default: 6697 },
      { key: 'nick', label: 'Nickname', type: 'text' },
      { key: 'username', label: 'Username', type: 'text' },
      { key: 'channels', label: 'Channels', type: 'list', default: [], hint: 'e.g. #general' },
      { key: 'allow_from', label: 'Allow From', type: 'list', default: [] },
      { key: 'server_password', label: 'Server Password', type: 'password' },
      { key: 'nickserv_password', label: 'NickServ Password', type: 'password' },
      { key: 'sasl_password', label: 'SASL Password', type: 'password' },
      { key: 'tls', label: 'TLS', type: 'toggle', default: true },
    ]
  },
  imessage: {
    label: 'iMessage',
    hasAccounts: true,
    fields: [
      { key: 'enabled', label: 'Enabled', type: 'toggle', default: false },
      { key: 'allow_from', label: 'Allow From', type: 'list', default: [] },
      { key: 'group_allow_from', label: 'Group Allow From', type: 'list', default: [] },
      { key: 'group_policy', label: 'Group Policy', type: 'select', options: ['allowlist', 'open'], default: 'allowlist' },
      { key: 'db_path', label: 'DB Path', type: 'text' },
    ]
  },
  email: {
    label: 'Email',
    hasAccounts: true,
    fields: [
      { key: 'imap_host', label: 'IMAP Host', type: 'text' },
      { key: 'imap_port', label: 'IMAP Port', type: 'number', default: 993 },
      { key: 'imap_folder', label: 'IMAP Folder', type: 'text', default: 'INBOX' },
      { key: 'smtp_host', label: 'SMTP Host', type: 'text' },
      { key: 'smtp_port', label: 'SMTP Port', type: 'number', default: 587 },
      { key: 'smtp_tls', label: 'SMTP TLS', type: 'toggle', default: true },
      { key: 'username', label: 'Username', type: 'text' },
      { key: 'password', label: 'Password', type: 'password' },
      { key: 'from_address', label: 'From Address', type: 'text' },
      { key: 'poll_interval_secs', label: 'Poll Interval (secs)', type: 'number', default: 60 },
      { key: 'allow_from', label: 'Allow From', type: 'list', default: [] },
    ]
  },
  lark: {
    label: 'Lark/Feishu',
    hasAccounts: true,
    fields: [
      { key: 'app_id', label: 'App ID', type: 'text' },
      { key: 'app_secret', label: 'App Secret', type: 'password' },
      { key: 'encrypt_key', label: 'Encrypt Key', type: 'password' },
      { key: 'verification_token', label: 'Verification Token', type: 'password' },
      { key: 'use_feishu', label: 'Use Feishu', type: 'toggle', default: false },
      { key: 'allow_from', label: 'Allow From', type: 'list', default: [] },
      { key: 'receive_mode', label: 'Receive Mode', type: 'select', options: ['websocket', 'webhook'], default: 'websocket' },
    ]
  },
  dingtalk: {
    label: 'DingTalk',
    hasAccounts: true,
    fields: [
      { key: 'client_id', label: 'Client ID', type: 'text' },
      { key: 'client_secret', label: 'Client Secret', type: 'password' },
      { key: 'allow_from', label: 'Allow From', type: 'list', default: [] },
    ]
  },
  signal: {
    label: 'Signal',
    hasAccounts: true,
    fields: [
      { key: 'http_url', label: 'HTTP URL', type: 'text' },
      { key: 'account', label: 'Account', type: 'text' },
      { key: 'allow_from', label: 'Allow From', type: 'list', default: [] },
      { key: 'group_allow_from', label: 'Group Allow From', type: 'list', default: [] },
      { key: 'group_policy', label: 'Group Policy', type: 'select', options: ['allowlist', 'open'], default: 'allowlist' },
      { key: 'ignore_attachments', label: 'Ignore Attachments', type: 'toggle', default: false },
      { key: 'ignore_stories', label: 'Ignore Stories', type: 'toggle', default: false },
    ]
  },
  line: {
    label: 'LINE',
    hasAccounts: true,
    fields: [
      { key: 'access_token', label: 'Access Token', type: 'password' },
      { key: 'channel_secret', label: 'Channel Secret', type: 'password' },
      { key: 'allow_from', label: 'Allow From', type: 'list', default: [] },
    ]
  },
  qq: {
    label: 'QQ',
    hasAccounts: true,
    fields: [
      { key: 'app_id', label: 'App ID', type: 'text' },
      { key: 'app_secret', label: 'App Secret', type: 'password' },
      { key: 'bot_token', label: 'Bot Token', type: 'password' },
      { key: 'sandbox', label: 'Sandbox', type: 'toggle', default: false },
      { key: 'receive_mode', label: 'Receive Mode', type: 'select', options: ['websocket', 'webhook'], default: 'webhook' },
      { key: 'group_policy', label: 'Group Policy', type: 'select', options: ['allow', 'allowlist'], default: 'allow' },
      { key: 'allowed_groups', label: 'Allowed Groups', type: 'list', default: [] },
      { key: 'allow_from', label: 'Allow From', type: 'list', default: [] },
    ]
  },
  onebot: {
    label: 'OneBot',
    hasAccounts: true,
    fields: [
      { key: 'url', label: 'WebSocket URL', type: 'text', default: 'ws://localhost:6700' },
      { key: 'access_token', label: 'Access Token', type: 'password' },
      { key: 'group_trigger_prefix', label: 'Group Trigger Prefix', type: 'text' },
      { key: 'allow_from', label: 'Allow From', type: 'list', default: [] },
    ]
  },
  maixcam: {
    label: 'MaixCam',
    hasAccounts: true,
    fields: [
      { key: 'port', label: 'Port', type: 'number', default: 7777 },
      { key: 'host', label: 'Host', type: 'text', default: '0.0.0.0' },
      { key: 'allow_from', label: 'Allow From', type: 'list', default: [] },
      { key: 'name', label: 'Name', type: 'text', default: 'maixcam' },
    ]
  },
  web: {
    label: 'Web',
    hasAccounts: true,
    fields: [
      { key: 'transport', label: 'Transport', type: 'select', options: ['local', 'relay'], default: 'local' },
      { key: 'max_connections', label: 'Max Connections', type: 'number', default: 10 },
      { key: 'auth_token', label: 'Auth Token', type: 'password' },
      { key: 'message_auth_mode', label: 'Auth Mode', type: 'select', options: ['pairing', 'token'], default: 'pairing' },
      { key: 'allowed_origins', label: 'Allowed Origins', type: 'list', default: [] },
      { key: 'relay_url', label: 'Relay URL', type: 'text', hint: 'Must start with wss://' },
      { key: 'relay_agent_id', label: 'Relay Agent ID', type: 'text', default: 'default' },
      { key: 'relay_token', label: 'Relay Token', type: 'password' },
    ]
  },
  nostr: {
    label: 'Nostr',
    hasAccounts: false,
    fields: [
      { key: 'private_key', label: 'Private Key', type: 'password', hint: 'enc2:-encrypted' },
      { key: 'owner_pubkey', label: 'Owner Pubkey', type: 'text', hint: '64-char lowercase hex' },
      { key: 'relays', label: 'Relays', type: 'list', default: [] },
      { key: 'dm_relays', label: 'DM Relays', type: 'list', default: [] },
      { key: 'dm_allowed_pubkeys', label: 'DM Allowed Pubkeys', type: 'list', default: [] },
      { key: 'display_name', label: 'Display Name', type: 'text', default: 'NullClaw' },
      { key: 'about', label: 'About', type: 'text', default: 'AI assistant' },
      { key: 'nip05', label: 'NIP-05', type: 'text' },
    ]
  },
  webhook: {
    label: 'Webhook',
    hasAccounts: false,
    fields: [
      { key: 'secret', label: 'Secret', type: 'password' },
    ]
  }
};

export interface SectionDef {
  key: string;
  label: string;
  fields: FieldDef[];
}

export const staticSections: SectionDef[] = [
  {
    key: 'models',
    label: 'Models & Providers',
    fields: [
      { key: 'default_temperature', label: 'Default Temperature', type: 'number', default: 0.7, min: 0, max: 2, step: 0.1 },
      { key: 'agents.defaults.model.primary', label: 'Default Model', type: 'text', hint: 'e.g. openrouter/anthropic/claude-sonnet-4.6' },
    ]
  },
  {
    key: 'agent',
    label: 'Agent',
    fields: [
      { key: 'agent.max_tool_iterations', label: 'Max Tool Iterations', type: 'number', default: 25 },
      { key: 'agent.max_history_messages', label: 'Max History Messages', type: 'number', default: 50 },
      { key: 'agent.session_idle_timeout_secs', label: 'Session Idle Timeout (secs)', type: 'number', default: 1800 },
      { key: 'agent.parallel_tools', label: 'Parallel Tools', type: 'toggle', default: false },
      { key: 'agent.compact_context', label: 'Compact Context', type: 'toggle', default: false },
      { key: 'agent.message_timeout_secs', label: 'Message Timeout (secs)', type: 'number', default: 300 },
    ]
  },
  {
    key: 'autonomy',
    label: 'Autonomy',
    fields: [
      { key: 'autonomy.level', label: 'Level', type: 'select', options: ['supervised', 'autonomous', 'off'], default: 'supervised' },
      { key: 'autonomy.workspace_only', label: 'Workspace Only', type: 'toggle', default: true },
      { key: 'autonomy.max_actions_per_hour', label: 'Max Actions / Hour', type: 'number', default: 20 },
      { key: 'autonomy.require_approval_for_medium_risk', label: 'Require Approval (Medium Risk)', type: 'toggle', default: true },
      { key: 'autonomy.block_high_risk_commands', label: 'Block High Risk Commands', type: 'toggle', default: true },
    ]
  },
  {
    key: 'diagnostics',
    label: 'Diagnostics',
    fields: [
      { key: 'diagnostics.log_tool_calls', label: 'Log Tool Calls', type: 'toggle', default: true },
      { key: 'diagnostics.log_message_receipts', label: 'Log Message Receipts', type: 'toggle', default: true },
      { key: 'diagnostics.log_message_payloads', label: 'Log Message Payloads', type: 'toggle', default: false },
      { key: 'diagnostics.log_llm_io', label: 'Log LLM I/O', type: 'toggle', default: false },
    ]
  }
];
