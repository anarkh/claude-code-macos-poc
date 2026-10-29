import { realpath } from 'node:fs/promises';
import { userInfo } from 'node:os';

export async function resolveHostHome() {
  // The isolated launchers override HOME; use the OS user record instead.
  const declared = userInfo().homedir;
  const canonical = await realpath(declared);
  return { path: canonical, aliases: [...new Set([declared, canonical])] };
}

export function createPocSandboxProfile({ sdkRoot, hostHome, port }) {
  return `(version 1)\n(allow default)\n(deny network*)\n(allow network-outbound (remote ip "localhost:${port}"))\n(deny file-write*)\n(allow file-write* (subpath ${JSON.stringify(sdkRoot)}) (literal "/dev/null") (literal "/dev/tty"))\n(deny file-read* (subpath ${JSON.stringify(hostHome)}) (subpath "/Library/Application Support/ClaudeCode") (subpath "/Library/Keychains"))\n(allow file-read* (subpath ${JSON.stringify(sdkRoot)}))\n(deny process-exec (literal "/usr/bin/security"))\n`;
}

export function serializePocSummary(summary, sdkRoot, hostHomeAliases) {
  let serialized = JSON.stringify(summary, null, 2);
  const replacements = [[sdkRoot, '<SDK_DIR>'],
    ...hostHomeAliases.map(home => [home, '<HOST_USER_HOME>'])];
  for (const [original, replacement] of replacements) {
    const variants = new Set([original]);
    let escaped = original;
    // The sandbox profile quotes paths once before the summary quotes it again.
    for (let depth = 0; depth < 2; depth++) {
      escaped = JSON.stringify(escaped).slice(1, -1);
      variants.add(escaped);
    }
    for (const variant of [...variants].sort((a, b) => b.length - a.length)) {
      serialized = serialized.replaceAll(variant, replacement);
    }
  }
  return serialized;
}
