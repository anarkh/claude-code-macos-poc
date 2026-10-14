// Offline official-artifact fixture: downloaded on 2026-10-13 from
// downloads.claude.ai/claude-code-releases/2.1.296 through the numeric loopback
// proxy with strict TLS. Preserve these bytes: OpenPGP signs the raw JSON.
import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { OFFICIAL_KEY_FINGERPRINT, OFFICIAL_KEY_SHA256, PINNED_KEY_ARMORED,
  OfficialIntegrityError, verifyOfficialManifest } from './official-integrity.mjs';

const MANIFEST = Buffer.from([
  'ewogICJ2ZXJzaW9uIjogIjIuMS4yOTYiLAogICJtYW5pZmVzdFNpZ25hdHVyZUVuZm9yY2VtZW50IjogImZsYWciLAogICJjb21t',
  'aXQiOiAiZmRiNmMxN2E5N2I2ZTBlM2NmMTVlMzU2NjY2M2ZjYTU4ZTdjNDNhOSIsCiAgImJ1aWxkRGF0ZSI6ICIyMDI2LTEwLTA5',
  'VDE0OjQ2OjM1WiIsCiAgInBsYXRmb3JtcyI6IHsKICAgICJkYXJ3aW4tYXJtNjQiOiB7CiAgICAgICJiaW5hcnkiOiAiY2xhdWRl',
  'IiwKICAgICAgImNoZWNrc3VtIjogImM5YjUzNDE2MzdiZWNiZDQyM2RkZmZjNWIyNTRhZmI2NDU2ODJhMzg2OGNiNzA4YmJjNmNj',
  'MGU3YmI0MTk5MzciLAogICAgICAic2l6ZSI6IDI0MDY2NDQzMgogICAgfSwKICAgICJkYXJ3aW4teDY0IjogewogICAgICAiYmlu',
  'YXJ5IjogImNsYXVkZSIsCiAgICAgICJjaGVja3N1bSI6ICJhNmJmNGYzMGJlMjQxMDUzYTkyM2YzODIwYWQyM2M1OTkxZDJmNWFj',
  'MjkzNWIzYThkZDY0ZGEyMThkOWNjNjAzIiwKICAgICAgInNpemUiOiAyNDkxOTQ3NTIKICAgIH0sCiAgICAibGludXgtYXJtNjQi',
  'OiB7CiAgICAgICJiaW5hcnkiOiAiY2xhdWRlIiwKICAgICAgImNoZWNrc3VtIjogImYxZjZlOTZlMGQ4MzQyYjlkYmY0MWQ3ZTg4',
  'MjU1Mzk3YTZhNTJjZTNkODczNmFkNmE0YzZiNTljOWI2MmZlZmEiLAogICAgICAic2l6ZSI6IDI1NjQzNDE2OAogICAgfSwKICAg',
  'ICJsaW51eC14NjQiOiB7CiAgICAgICJiaW5hcnkiOiAiY2xhdWRlIiwKICAgICAgImNoZWNrc3VtIjogIjI0OTcyZTNiYzg1OWZh',
  'YjJiNDZlZDRjMWU1MWY3ZDYxMzBmMDZkM2JkNTUwODExYTExNDY0MGRlMzM3MGQwZGUiLAogICAgICAic2l6ZSI6IDI1NzA2ODIx',
  'NgogICAgfSwKICAgICJsaW51eC1hcm02NC1tdXNsIjogewogICAgICAiYmluYXJ5IjogImNsYXVkZSIsCiAgICAgICJjaGVja3N1',
  'bSI6ICJiMGJiYzkzNmE4MjkzMDkzM2Q3ZDU2NDUwODEwNTBkNWY4MjdhOTQ2Y2Y2YWJjNjU3NTM4M2I3NzdhMGZlZWMwIiwKICAg',
  'ICAgInNpemUiOiAyNDg3ODg4MDAKICAgIH0sCiAgICAibGludXgteDY0LW11c2wiOiB7CiAgICAgICJiaW5hcnkiOiAiY2xhdWRl',
  'IiwKICAgICAgImNoZWNrc3VtIjogIjk0YTFjY2M2ZmZjOWIwODg5YzZiMmI4MGUyMDI4ODVjOGE1NzU3NjY3NzUzNzczOThkYWE0',
  'ZGI1ZmQ4OTQxN2YiLAogICAgICAic2l6ZSI6IDI1MDgxODY0OAogICAgfSwKICAgICJ3aW4zMi14NjQiOiB7CiAgICAgICJiaW5h',
  'cnkiOiAiY2xhdWRlLmV4ZSIsCiAgICAgICJjaGVja3N1bSI6ICI3NmRlNzRmNzY5NGE1YmRjMDMzNzhhNWY4MzdjOWUxMzI4Mjdi',
  'ZjAwNGM5OGMyNzZiYzRlOTA5NGZmMDY3NjlhIiwKICAgICAgInNpemUiOiAyNjA0ODkzNzYKICAgIH0sCiAgICAid2luMzItYXJt',
  'NjQiOiB7CiAgICAgICJiaW5hcnkiOiAiY2xhdWRlLmV4ZSIsCiAgICAgICJjaGVja3N1bSI6ICJhNjUyYTE3ZjVhMzI0ZDJkOWFk',
  'OTk5NWNjMDQ3MTQ1ZjgxNzZiOWE0YjRmMjhiYmQzYWEwNzA4YTIyNjc5ZTNiIiwKICAgICAgInNpemUiOiAyNDgwMTM5ODQKICAg',
  'IH0KICB9LAogICJzZGtDb21wYXQiOiB7CiAgICAidGVzdGVkV3JhcHBlclZlcnNpb25zIjogWwogICAgICAiMC4zLjI2MSIsCiAg',
  'ICAgICIwLjMuMjYzIiwKICAgICAgIjAuMy4yNjUiLAogICAgICAiMC4zLjI2NiIsCiAgICAgICIwLjMuMjY3IiwKICAgICAgIjAu',
  'My4yNjgiLAogICAgICAiMC4zLjI2OSIsCiAgICAgICIwLjMuMjcwIiwKICAgICAgIjAuMy4yNzEiLAogICAgICAiMC4zLjI3MiIs',
  'CiAgICAgICIwLjMuMjczIiwKICAgICAgIjAuMy4yNzQiLAogICAgICAiMC4zLjI3NSIsCiAgICAgICIwLjMuMjc2IiwKICAgICAg',
  'IjAuMy4yNzciLAogICAgICAiMC4zLjI3OCIsCiAgICAgICIwLjMuMjgwIiwKICAgICAgIjAuMy4yODEiLAogICAgICAiMC4zLjI4',
  'MiIsCiAgICAgICIwLjMuMjg1IgogICAgXSwKICAgICJoYXJuZXNzU2NoZW1hIjogMQogIH0KfQo=',
].join(''), 'base64');
const SIGNATURE = Buffer.from([
  'LS0tLS1CRUdJTiBQR1AgU0lHTkFUVVJFLS0tLS0KCmlRSXpCQUFCQ2dBZEZpRUVNZDNlSk4zNnRubjBMWHZTdXFrcC94cCt5czRG',
  'QW1ySS9zQUFDZ2tRdXFrcC94cCsKeXM3TExBLy9ZTFB2M2lPU1dqL2NvWXZrRW1oMTFzdzIyZ3FaVW15cEdYOUlGVzhWenBKVHNC',
  'Szd3Z1ZrL0F5VApLRzA4dVo0dG5lbmY3Rjg0aHBKVGpuUnRMWCtDS2xVR2E2YmVKeDlvQ1Ywd3BRSmEzWnpSc0RhSmpzYlE5QWNz',
  'ClVVbW01dk5hSGJKUE4xWVVVZUdCMVJCNHlMejRnUCtxWUdzM3B6Q2NQWXJlMVE3NzhkelNob1plaXZDbWc2OUYKS0Jna2hWWENp',
  'QTNZUjkrRlVaazFNNXdacXphamJaajREOG10bUlWQ205TmFONmdXUmJIZUkzQXc5OTZHdXJBWApSMzRUS2dIbERueTRlaFNJWmY2',
  'ZFY0TXNoN2pJVEdmeUt5azZabmFGYWlqZU1qUk5NQ01iZXgyZ3VvTzJLb0l1CllTNko2T29DZlBZTlk5STJsVmZzeG5VbHZpQU53',
  'ZlFnWmhYTmltYkxLaUQ1Ukpna0lYLzdYNFIveVZEdGNUTjEKUWRkTHhKWFoxQ1JXeXpKRTlUT095eVBHVUlKSTNFM1kwaXZVN25w',
  'Rm0xQmt4UCthMEFQQU93UDlWZTBySDZqagpsMDZ0TUtYTFc5MzVZMXNMVHZBRStKNDBnSnhBOWtrUWs5L0pPT2hMNHdTUm5lWE9m',
  'Tk93ZUZMUFE2NjZNN08rCkhrQW9nd1VaOXJTUnRPaGprRklJNkEyelVYVWxjUFdsdVpteGtOYUdjVWNJVU92R0xjVTdaNU1JUlFS',
  'NmM4eVoKRkZkZXlIYU5kZzcvOGxWV2lrTGN3Qk1tRVdTMm44YXF5UXJxSDNXOGYya21hdVd0Ulg3NERCTGVuSk10MVp0UApQaDJy',
  'ckhUZ3Ruc2tRVkMrcXo1OXdkam1JYTFqVUFnL216SkREaGdTL3B6SU8rejVOZnc9Cj14dnhyCi0tLS0tRU5EIFBHUCBTSUdOQVRV',
  'UkUtLS0tLQo=',
].join(''), 'base64');
const EXPECTED_FINGERPRINT = '31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE';
const EXPECTED_KEY_SHA256 = 'bd70a5e4a268002704024ceba7f8446024114e94f3f0bdd11c23a9e592be81c6';
const EXPECTED_MANIFEST_SHA256 = 'e50e872d91f3b7da2fb3d8d38505d709e0a90f48da1951dd51176930c8da8270';
const EXPECTED_CLI_SHA256 = 'f1f6e96e0d8342b9dbf41d7e88255397a6a52ce3d8736ad6a4c6b59c9b62fefa';

function assertInvalid(manifest, signature, code = 'OFFICIAL_SIGNATURE_INVALID') {
  assert.throws(() => verifyOfficialManifest(manifest, signature),
    error => error instanceof OfficialIntegrityError && error.code === code);
}
function signaturePacket() {
  const lines = SIGNATURE.toString('ascii').trimEnd().split('\n');
  const bytes = Buffer.from(lines.slice(2, -2).join(''), 'base64');
  // This fixed fixture has an old-format tag 2 header and a 563-byte body.
  assert.equal(bytes.subarray(0, 3).toString('hex'), '890233');
  return bytes;
}
function armorSignature(bytes) {
  let crc = 0xb704ce;
  for (const byte of bytes) {
    crc ^= byte << 16;
    for (let bit = 0; bit < 8; bit++) {
      crc <<= 1;
      if (crc & 0x1000000) crc ^= 0x1864cfb;
    }
  }
  const checksum = Buffer.alloc(3);
  checksum.writeUIntBE(crc & 0xffffff, 0, 3);
  return Buffer.from(['-----BEGIN PGP SIGNATURE-----', '',
    ...bytes.toString('base64').match(/.{1,64}/g), '=' + checksum.toString('base64'),
    '-----END PGP SIGNATURE-----', ''].join('\n'));
}
function changedSignatureBodyByte(offset, value) {
  const bytes = signaturePacket();
  bytes[3 + offset] = value;
  return armorSignature(bytes);
}

test('official pin identifies the exact downloaded key bytes', () => {
  assert.equal(OFFICIAL_KEY_FINGERPRINT, EXPECTED_FINGERPRINT);
  assert.equal(OFFICIAL_KEY_SHA256, EXPECTED_KEY_SHA256);
  assert.equal(createHash('sha256').update(PINNED_KEY_ARMORED).digest('hex'), EXPECTED_KEY_SHA256);
});

test('official RSA/SHA512 detached signature admits the exact linux-arm64 manifest', () => {
  assert.equal(MANIFEST.length, 1931);
  const verified = verifyOfficialManifest(MANIFEST, SIGNATURE);
  assert.equal(verified.manifest.version, '2.1.296');
  assert.equal(verified.manifestSHA256, EXPECTED_MANIFEST_SHA256);
  assert.equal(verified.signingKeySHA256, EXPECTED_KEY_SHA256);
  assert.equal(verified.signingKeyFingerprint, EXPECTED_FINGERPRINT);
  assert.deepEqual(verified.platform, { sha256: EXPECTED_CLI_SHA256, size: 256434168 });
});

test('JSON reserialization and removing the final newline invalidate the signature', () => {
  assert.equal(MANIFEST.at(-1), 10);
  assertInvalid(Buffer.from(JSON.stringify(JSON.parse(MANIFEST))), SIGNATURE);
  assertInvalid(MANIFEST.subarray(0, -1), SIGNATURE);
});

test('tampering with a manifest value is rejected', () => {
  const changed = Buffer.from(MANIFEST);
  const version = changed.indexOf(Buffer.from('2.1.296'));
  assert.notEqual(version, -1);
  changed[version + 6] = '5'.charCodeAt(0);
  assertInvalid(changed, SIGNATURE);
});

test('tampering with RSA signature bytes is rejected after a valid armor checksum', () => {
  const bytes = signaturePacket();
  bytes[bytes.length - 1] ^= 1;
  assertInvalid(MANIFEST, armorSignature(bytes));
});

test('an inconsistent unhashed issuer key ID is rejected', () => {
  // Body offset 39 is the first issuer ID byte, outside the signed hash area.
  const bytes = signaturePacket();
  bytes[3 + 39] ^= 1;
  assertInvalid(MANIFEST, armorSignature(bytes));
});

test('unsupported signature version, text signature, public-key and hash algorithms are rejected', () => {
  for (const [offset, value] of [[0, 5], [1, 1], [2, 22], [3, 8]]) {
    assertInvalid(MANIFEST, changedSignatureBodyByte(offset, value));
  }
});

test('malformed signature armor and incorrect CRC24 are rejected', () => {
  const text = SIGNATURE.toString('ascii');
  assertInvalid(MANIFEST, Buffer.from(text.replace('BEGIN PGP SIGNATURE', 'BEGIN PGP MESSAGE')));
  assertInvalid(MANIFEST, Buffer.from(text.replace('-----END PGP SIGNATURE-----', '')));
  assertInvalid(MANIFEST, Buffer.from(text.replace(/=[A-Za-z0-9+/]{4}\n-----END/, '=AAAA\n-----END')));
  assertInvalid(MANIFEST, Buffer.from(text.replace('\n\n', '\n\n!')));
});

test('truncated packets, trailing bytes and extra packets are rejected', () => {
  const bytes = signaturePacket();
  assertInvalid(MANIFEST, armorSignature(bytes.subarray(0, bytes.length - 1)));
  assertInvalid(MANIFEST, armorSignature(Buffer.concat([bytes, Buffer.from([0])])));
  assertInvalid(MANIFEST, armorSignature(Buffer.concat([bytes, bytes])));
});

test('manifest and signature inputs are bounded and require byte buffers', () => {
  assertInvalid(Buffer.alloc(0), SIGNATURE, 'OFFICIAL_MANIFEST_INVALID');
  assertInvalid(Buffer.alloc(65537), SIGNATURE, 'OFFICIAL_MANIFEST_INVALID');
  assertInvalid(MANIFEST.toString('utf8'), SIGNATURE, 'OFFICIAL_MANIFEST_INVALID');
  assertInvalid(MANIFEST, Buffer.alloc(0));
  assertInvalid(MANIFEST, Buffer.alloc(4097));
  assertInvalid(MANIFEST, SIGNATURE.toString('ascii'));
});

