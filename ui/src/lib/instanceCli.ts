export type InstanceCliError = {
  error: string;
  message?: string;
  stderr?: string;
  stdout?: string;
  backend?: string;
};

export function isInstanceCliError(value: unknown): value is InstanceCliError {
  return Boolean(
    value &&
      typeof value === 'object' &&
      !Array.isArray(value) &&
      'error' in (value as Record<string, unknown>),
  );
}

export function isLegacyCliError(value: unknown): boolean {
  if (!isInstanceCliError(value)) return false;
  const text = [value.error, value.message, value.stderr, value.stdout]
    .filter(Boolean)
    .join(' ')
    .toLowerCase();
  return (
    text.includes('unknown') ||
    text.includes('usage:') ||
    text.includes('invalid_cli_response') ||
    text.includes('not recognized') ||
    text.includes('unsupported')
  );
}

export function describeInstanceCliError(value: unknown, fallback = 'Data is unavailable.'): string {
  if (!isInstanceCliError(value)) return fallback;
  if (isLegacyCliError(value)) {
    return 'Update nullclaw to a build that supports this tab.';
  }
  if (value.message && value.message.length > 0) return value.message;
  if (value.error && value.error.length > 0) return value.error.replaceAll('_', ' ');
  return fallback;
}
