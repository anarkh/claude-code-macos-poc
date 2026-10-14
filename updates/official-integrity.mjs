// Bounded OpenPGP v4 detached RSA/SHA512 verification, using a pinned official
// Anthropic key. No key server, gpg executable or runtime dependency is needed.
import { createHash, createPublicKey, verify, constants } from 'node:crypto';
import { createReadStream } from 'node:fs';
import { createGunzip } from 'node:zlib';

export const OFFICIAL_KEY_FINGERPRINT = '31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE';
export const PINNED_KEY_ARMORED = `-----BEGIN PGP PUBLIC KEY BLOCK-----\n\nmQINBGnK73ABEACnbytJXkjweYrwIr0aLEFRlH+C0nF44KxFc7gQmJ6PjSPMGZAD\ndxZcaixU7zZl8WxEpVO0wLmIH8cf2zGOdyuZg1Yaugk1vHb2b8WBhAGCQJdPgB8W\nXquedepEYtk56uP/gCoTjJDUZluEGBHnlnuujSJ4orxEdhSykEoAUfJZGEILPpMd\nbphFt/Sn+Eb/TxM5jpKPdwnv8AShNF/1mZU1fWTQq9tRKJUakZj04gdaDFElQXak\nCtTij+GT6yoYCARSHwGO+PC/Pr6q4tc+D7LRjxSBvUWDoFSmlqb/PJ1hj9D/7I2O\ne4XXniAPWMR56KvxHlzOzrNQdJujbJdSkCwh1ZijkSd3y8ayW5WYUTGdRab99NUw\nagzlabe/VVF6kzJ0Scn5q3PihB2Y9Bwo0CKnkYk7a7KT77EWv0Kkq+VHmOtqX3a2\nhhX+b6a6ve9rzJ1qZYGj+obv/C3Sx1LzUjAfqVy7RJDf2uAoP5t2g8u/TkSpUxhM\nVEjZBkSxYZhMyzQM6t8IgkUfnSrIPTHixbDWARZ4beMOBjxyPZK1nP7OOrNR3TkK\nJtwLMQAabURCDnL0PjS0iwBTU4jtumBD1XSULyWuoTvMljrpQr1nV1oDyOt0OLqa\nKA2McWtd9PdXhC8y2EIg7TmrTlJLfHYbdmkiCYj4J49Q8HWkN/6WE+RTUwARAQAB\ntD5BbnRocm9waWMgQ2xhdWRlIENvZGUgUmVsZWFzZSBTaWduaW5nIDxzZWN1cml0\neUBhbnRocm9waWMuY29tPokCUQQTAQoAOxYhBDHd3iTd+rZ59C170rqpKf8afsrO\nBQJpyu9wAhsPBQsJCAcCAiICBhUKCQgLAgQWAgMBAh4HAheAAAoJELqpKf8afsrO\nl5IP/2I8X1dFy5xYczWB/coIxGjuzS/V6ByZGZZEJsbr04pmuHiFUykJqPGWGQ6q\nU0YF5iEwvEkaagS5m7DzhSEf3FM3Cgafax/6d70tar9Vr1D+w6uPfxetu7u/WYJp\naolIsdh5fTrBh9zSM1Njl8FM8wG8CwZQjS33Oa7d8cwRkgdUWbt6LXgz+cTQNuBn\nBgW6Ks7oZFI25dfu0ojDR+aDFJg4+4wZoyDLPvJz1SIrJ5WFGs67zsx9SfS3yZnf\nXKmBe+f0dUy+GJ2nFZrXFf99+c0dPEHYO8DCeAHZizjkFrdYtUHdDU0YDYEGkLJa\nbE+pgcpkHf5EvsZzHsyDbl95W/eh7pcXMbwkN+W4CBYUE9X4uHhqzWaC5yAVRWUA\n1BJ9V4LjZfHPLEJt0I3TxzXiEg9/BVeaTYq9RjaxIFo9Nfk158HqJY6SA5jslBlx\nGv/No8u+xVcze2UJyGVfEIUfm92+0UAIkny3+5cuVV0ICzJxXlXj0CnLM9Lt50wE\np3suVwuBEviCbZ08eAH1Ht8gbBdSsiOkIU8CX3v/scwHHx5q0+NBL6xLrQObg13a\ntRXBlKObfElkPN3lTUbUnJOW4U8uSjH8VRP+AujKWMDFe7x0zCs+iYY1mTOvbrTS\n9n3CmZUmbynZ+E/QWNENpW/pDNZdWFy43PASmML5FHu4m9Sn\n=oqMI\n-----END PGP PUBLIC KEY BLOCK-----\n`;
export const OFFICIAL_KEY_SHA256 = createHash('sha256').update(PINNED_KEY_ARMORED).digest('hex');
export class OfficialIntegrityError extends Error {
  constructor(code = 'OFFICIAL_SIGNATURE_INVALID') { super(code); this.name = 'OfficialIntegrityError'; this.code = code; }
}
const bad = (code = 'OFFICIAL_SIGNATURE_INVALID') => { throw new OfficialIntegrityError(code); };
const sha = bytes => createHash('sha256').update(bytes).digest('hex');
function crc24(bytes) {
  let crc = 0xb704ce;
  for (const byte of bytes) { crc ^= byte << 16; for (let i = 0; i < 8; i++) { crc <<= 1; if (crc & 0x1000000) crc ^= 0x1864cfb; } }
  return crc & 0xffffff;
}
function armor(input, label, maximum) {
  if (!Buffer.isBuffer(input) || input.length < 1 || input.length > maximum) bad();
  const text = input.toString('ascii');
  if (!input.equals(Buffer.from(text, 'ascii'))) bad();
  const lines = text.replace(/\r\n/g, '\n').trimEnd().split('\n');
  if (lines.shift() !== `-----BEGIN PGP ${label}-----` || lines.shift() !== '' || lines.pop() !== `-----END PGP ${label}-----`) bad();
  const checksum = lines.pop();
  if (!/^=[A-Za-z0-9+/]{4}$/.test(checksum ?? '') || !lines.length || lines.some(line => !/^[A-Za-z0-9+/]+={0,2}$/.test(line) || line.length > 76)) bad();
  const encoded = lines.join('');
  const bytes = Buffer.from(encoded, 'base64');
  if (!bytes.length || bytes.toString('base64') !== encoded) bad();
  const crc = Buffer.from(checksum.slice(1), 'base64');
  if (crc.readUIntBE(0, 3) !== crc24(bytes)) bad();
  return bytes;
}
function lengthAt(bytes, offset, end = bytes.length) {
  if (offset >= end) bad();
  const first = bytes[offset++];
  if (first < 192) return { size: first, offset };
  if (first < 224) { if (offset >= end) bad(); return { size: ((first - 192) << 8) + bytes[offset++] + 192, offset }; }
  if (first === 255) { if (offset + 4 > end) bad(); return { size: bytes.readUInt32BE(offset), offset: offset + 4 }; }
  bad(); // partial and indefinite packet lengths are not accepted.
}
function packets(bytes) {
  const result = []; let offset = 0;
  while (offset < bytes.length) {
    if (result.length >= 16) bad();
    const header = bytes[offset++];
    if (!(header & 0x80)) bad();
    let tag, size;
    if (header & 0x40) { tag = header & 63; const value = lengthAt(bytes, offset); size = value.size; offset = value.offset; }
    else {
      tag = (header >> 2) & 15; const kind = header & 3, count = [1, 2, 4][kind];
      if (!count || offset + count > bytes.length) bad();
      size = bytes.readUIntBE(offset, count); offset += count;
    }
    if (!size || size > 8192 || offset + size > bytes.length) bad();
    result.push({ tag, body: bytes.subarray(offset, offset + size) }); offset += size;
  }
  return result;
}
function mpi(bytes, offset) {
  if (offset + 2 > bytes.length) bad();
  const bits = bytes.readUInt16BE(offset), size = Math.ceil(bits / 8); offset += 2;
  if (!bits || size > 512 || offset + size > bytes.length) bad();
  const value = bytes.subarray(offset, offset + size);
  if (!value[0] || Math.floor(Math.log2(value[0])) + 1 + (size - 1) * 8 !== bits) bad();
  return { bits, value, offset: offset + size };
}
const keyPackets = packets(armor(Buffer.from(PINNED_KEY_ARMORED), 'PUBLIC KEY BLOCK', 4096));
if (keyPackets.length !== 3 || keyPackets[0].tag !== 6 || keyPackets[1].tag !== 13 || keyPackets[2].tag !== 2) bad();
const keyBody = keyPackets[0].body;
if (keyBody[0] !== 4 || keyBody[5] !== 1) bad();
const fingerprintHeader = Buffer.alloc(3); fingerprintHeader[0] = 0x99; fingerprintHeader.writeUInt16BE(keyBody.length, 1);
const actualFingerprint = createHash('sha1').update(fingerprintHeader).update(keyBody).digest('hex').toUpperCase();
if (actualFingerprint !== OFFICIAL_KEY_FINGERPRINT) bad();
const modulus = mpi(keyBody, 6), exponent = mpi(keyBody, modulus.offset);
if (modulus.bits !== 4096 || exponent.offset !== keyBody.length || !exponent.value.equals(Buffer.from([1, 0, 1]))) bad();
const PUBLIC_KEY = createPublicKey({ key: { kty: 'RSA', n: modulus.value.toString('base64url'), e: exponent.value.toString('base64url') }, format: 'jwk' });
function subpackets(bytes, hashed) {
  let offset = 0; const seen = new Set();
  while (offset < bytes.length) {
    const value = lengthAt(bytes, offset); offset = value.offset;
    if (value.size < 1 || value.size > 128 || offset + value.size > bytes.length) bad();
    const type = bytes[offset], data = bytes.subarray(offset + 1, offset + value.size); offset += value.size;
    if (seen.has(type)) bad(); seen.add(type);
    // Only the official issuer fingerprint, creation time and key ID are used.
    if (type === 33 && hashed) {
      if (data.length !== 21 || data[0] !== 4 || data.subarray(1).toString('hex').toUpperCase() !== OFFICIAL_KEY_FINGERPRINT) bad();
    } else if (type === 2 && hashed) { if (data.length !== 4) bad(); }
    else if (type === 16 && !hashed) { if (data.length !== 8 || data.toString('hex').toUpperCase() !== OFFICIAL_KEY_FINGERPRINT.slice(-16)) bad(); }
    else bad();
  }
  if (hashed && (!seen.has(33) || !seen.has(2))) bad();
  if (!hashed && !seen.has(16)) bad();
}
export function verifyOfficialManifest(manifestBytes, signatureBytes) {
  if (!Buffer.isBuffer(manifestBytes) || !manifestBytes.length || manifestBytes.length > 65536) bad('OFFICIAL_MANIFEST_INVALID');
  const signaturePackets = packets(armor(signatureBytes, 'SIGNATURE', 4096));
  if (signaturePackets.length !== 1 || signaturePackets[0].tag !== 2) bad();
  const signature = signaturePackets[0].body;
  if (signature.length < 10 || signature[0] !== 4 || signature[1] !== 0 || signature[2] !== 1 || signature[3] !== 10) bad();
  const hashedSize = signature.readUInt16BE(4), hashedEnd = 6 + hashedSize;
  if (hashedEnd + 2 > signature.length || hashedSize > 256) bad();
  subpackets(signature.subarray(6, hashedEnd), true);
  const unhashedSize = signature.readUInt16BE(hashedEnd), digestOffset = hashedEnd + 2 + unhashedSize;
  if (digestOffset + 4 > signature.length || unhashedSize > 128) bad();
  subpackets(signature.subarray(hashedEnd + 2, digestOffset), false);
  const signedHeader = signature.subarray(0, hashedEnd), trailer = Buffer.alloc(6);
  trailer[0] = 4; trailer[1] = 0xff; trailer.writeUInt32BE(signedHeader.length, 2);
  const data = Buffer.concat([manifestBytes, signedHeader, trailer]);
  const digest = createHash('sha512').update(data).digest();
  if (!digest.subarray(0, 2).equals(signature.subarray(digestOffset, digestOffset + 2))) bad();
  const signedMPI = mpi(signature, digestOffset + 2);
  if (signedMPI.offset !== signature.length) bad();
  const rsaSignature = Buffer.concat([Buffer.alloc(512 - signedMPI.value.length), signedMPI.value]);
  if (!verify('sha512', data, { key: PUBLIC_KEY, padding: constants.RSA_PKCS1_PADDING }, rsaSignature)) bad();
  let manifest;
  try { manifest = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(manifestBytes)); } catch { bad('OFFICIAL_MANIFEST_INVALID'); }
  const platform = manifest?.platforms?.['linux-arm64'];
  if (!manifest || typeof manifest !== 'object' || Array.isArray(manifest) || !/^\d{1,9}\.\d{1,9}\.\d{1,9}$/.test(manifest.version ?? '') ||
      platform?.binary !== 'claude' || !/^[a-f0-9]{64}$/.test(platform?.checksum ?? '') ||
      !Number.isSafeInteger(platform?.size) || platform.size < 1 || platform.size > 320 * 1024 ** 2) bad('OFFICIAL_MANIFEST_INVALID');
  return { manifest, platform: { sha256: platform.checksum, size: platform.size }, manifestSHA256: sha(manifestBytes),
    signingKeySHA256: OFFICIAL_KEY_SHA256, signingKeyFingerprint: OFFICIAL_KEY_FINGERPRINT };
}

// Read the native archive without extracting or executing downloaded code.
// All tar headers and decompressed bytes are bounded before hashing the CLI.
export async function inspectNativeArchive(filename, { version, cliSHA256, cliBytes, signal } = {}) {
  const code = 'OFFICIAL_ARTIFACT_INVALID';
  const names = new Set(['package/claude', 'package/package.json', 'package/LICENSE.md', 'package/README.md']);
  const seen = new Set(), stream = createReadStream(filename), gunzip = createGunzip();
  const cancel = () => { stream.destroy(new OfficialIntegrityError('OFFICIAL_CANCELLED')); gunzip.destroy(new OfficialIntegrityError('OFFICIAL_CANCELLED')); };
  stream.on('error', error => gunzip.destroy(error));
  signal?.addEventListener('abort', cancel, { once: true });
  stream.pipe(gunzip);
  let buffer = Buffer.alloc(0), total = 0, entry, padding = 0, ended = false, zeros = 0, cliDigest, packageJson;
  try {
    if (signal?.aborted) cancel();
    for await (const chunk of gunzip) {
      if (signal?.aborted) bad('OFFICIAL_CANCELLED');
      total += chunk.length;
      if (total > Math.min(320 * 1024 ** 2, cliBytes + 1024 * 1024)) bad(code);
      buffer = Buffer.concat([buffer, chunk]);
      for (;;) {
        if (padding) { if (!buffer.length) break; const used = Math.min(padding, buffer.length); if (buffer.subarray(0, used).some(byte => byte !== 0)) bad(code); padding -= used; buffer = buffer.subarray(used); continue; }
        if (entry) {
          if (!buffer.length) break;
          const used = Math.min(entry.remaining, buffer.length), bytes = buffer.subarray(0, used);
          if (entry.name === 'package/claude') entry.hash.update(bytes);
          if (entry.name === 'package/package.json') entry.chunks.push(bytes);
          entry.remaining -= used; buffer = buffer.subarray(used);
          if (entry.remaining === 0) {
            if (entry.name === 'package/claude') cliDigest = entry.hash.digest('hex');
            if (entry.name === 'package/package.json') packageJson = Buffer.concat(entry.chunks);
            padding = (512 - entry.size % 512) % 512; entry = undefined;
          }
          continue;
        }
        if (buffer.length < 512) break;
        const header = buffer.subarray(0, 512); buffer = buffer.subarray(512);
        if (header.every(byte => byte === 0)) { zeros++; ended = true; continue; }
        if (ended) bad(code);
        const text = (start, size) => { const field = header.subarray(start, start + size); const end = field.indexOf(0); if (end !== -1 && field.subarray(end).some(byte => byte !== 0)) bad(code); return field.subarray(0, end < 0 ? size : end).toString('ascii'); };
        const octal = (start, size) => { const value = header.subarray(start, start + size).toString('ascii').replace(/[\0 ]+$/g, '').replace(/^ +/g, ''); if (!/^[0-7]+$/.test(value)) bad(code); const result = Number.parseInt(value, 8); if (!Number.isSafeInteger(result)) bad(code); return result; };
        let checksum = 0; for (let i = 0; i < 512; i++) checksum += i >= 148 && i < 156 ? 32 : header[i];
        if (checksum !== octal(148, 8) || ![0, 48].includes(header[156]) || text(157, 100) !== '' || text(345, 155) !== '') bad(code);
        const name = text(0, 100), size = octal(124, 12);
        if (!names.has(name) || seen.has(name) || (name === 'package/claude' ? size !== cliBytes : size > 65536)) bad(code);
        seen.add(name); entry = { name, size, remaining: size, hash: createHash('sha256'), chunks: [] };
        if (!size) { padding = 0; entry = undefined; }
      }
    }
    if (entry || padding || buffer.length || zeros < 2 || seen.size !== names.size || cliDigest !== cliSHA256 || !packageJson) bad(code);
    let metadata; try { metadata = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(packageJson)); } catch { bad(code); }
    if (metadata.name !== '@anthropic-ai/claude-agent-sdk-linux-arm64' || metadata.version !== version ||
        !Array.isArray(metadata.os) || !metadata.os.includes('linux') || !Array.isArray(metadata.cpu) || !metadata.cpu.includes('arm64')) bad(code);
    return { cliSHA256: cliDigest, cliBytes, unpackedBytes: total, binaryMatchesSignedManifest: true };
  } catch (error) { if (signal?.aborted) bad('OFFICIAL_CANCELLED'); if (error instanceof OfficialIntegrityError) throw error; bad(code); }
  finally { signal?.removeEventListener('abort', cancel); stream.destroy(); gunzip.destroy(); }
}
