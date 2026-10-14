// Offline runtime-profile checks. No provider, API key, Keychain, or host
// timezone/language configuration is read or changed.
import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import {
  DEFAULT_RUNTIME_PROFILE, RUNTIME_PROFILE_SCHEMA, RUNTIME_ERROR_CODES,
  RuntimeProfileError, validateRuntimeProfile, profileEnvironment,
} from './profile.mjs';

const japan = { schema: 'app-runtime-profile/v1', timeZone: 'Asia/Tokyo', language: 'ja' };
const profile = changes => ({ ...japan, ...changes });
const runtimeEnvironmentKeys = ['TZ', 'LANG', 'LC_ALL', 'LC_MESSAGES'];
const parentRuntimeEnvironment = () => Object.fromEntries(
  runtimeEnvironmentKeys.map(key => [key, process.env[key]]),
);

function rejectsProfile(value, code = 'RUNTIME_PROFILE_INVALID') {
  assert.throws(() => validateRuntimeProfile(value), error => {
    assert.ok(error instanceof RuntimeProfileError);
    assert.equal(error.code, code);
    assert.equal(error.message, code, 'Errors must not echo untrusted profile values.');
    return true;
  });
}

test('Japan is the explicit default and runtime failures have finite codes', () => {
  assert.equal(RUNTIME_PROFILE_SCHEMA, japan.schema);
  assert.deepEqual(DEFAULT_RUNTIME_PROFILE, japan);
  assert.deepEqual(validateRuntimeProfile(DEFAULT_RUNTIME_PROFILE), japan);
  assert.ok(RUNTIME_ERROR_CODES.includes('RUNTIME_PROFILE_REQUIRED'));
  assert.ok(RUNTIME_ERROR_CODES.includes('RUNTIME_PROFILE_INVALID'));
});

for (const [label, value] of [['undefined', undefined], ['null', null]]) {
  test(`A ${label} profile fails as required`, () => rejectsProfile(value, 'RUNTIME_PROFILE_REQUIRED'));
}

for (const [label, value] of [
  ['array', [japan]], ['string', 'Asia/Tokyo'], ['number', 1], ['boolean', true],
]) {
  test(`A ${label} is not a profile object`, () => rejectsProfile(value));
}

for (const key of ['schema', 'timeZone', 'language']) {
  test(`A missing ${key} is invalid`, () => {
    const value = profile();
    delete value[key];
    rejectsProfile(value);
  });
}

test('Unknown profile fields cannot alter the environment', () => {
  rejectsProfile(profile({ LANG: 'unexpected', extra: true }));
});

test('An unknown schema is invalid', () => rejectsProfile(profile({ schema: 'app-runtime-profile/v2' })));

for (const [label, language] of [
  ['regional locale', 'ja-JP'], ['uppercase code', 'JA'], ['unsupported code', 'fr'],
  ['null', null], ['number', 1],
]) {
  test(`Language ${label} is rejected`, () => rejectsProfile(profile({ language })));
}

for (const [label, timeZone] of [
  ['unknown zone', 'Asia/Definitely_Not_A_Zone'], ['null', null], ['number', 9],
  ['bare GMT', 'GMT'], ['bare abbreviation', 'JST'], ['POSIX zone', 'JST-9'],
  ['colon-prefixed zone', ':Asia/Tokyo'], ['numeric offset', '+09:00'],
  ['lowercase identifier', 'asia/tokyo'], ['wrong component case', 'Asia/tokyo'],
  ['leading whitespace', ' Asia/Tokyo'], ['trailing whitespace', 'Asia/Tokyo '],
  ['newline', 'Asia/Tokyo\n'], ['embedded control', 'Asia/To\u0000kyo'],
  ['Unicode slash', 'Asia／Tokyo'], ['Unicode letters', 'Asia/Ｔokyo'],
]) {
  test(`Timezone ${label} is rejected`, () => rejectsProfile(profile({ timeZone })));
}

// Foundation exposes Europe/Kyiv while this Node ICU canonicalizes it to
// Europe/Kiev. Validation retains the user's accepted identifier.
for (const timeZone of ['UTC', 'Asia/Tokyo', 'Asia/Shanghai', 'America/New_York', 'Europe/London', 'Europe/Kyiv']) {
  test(`Timezone ${timeZone} is validated and retained`, () => {
    assert.equal(validateRuntimeProfile(profile({ timeZone })).timeZone, timeZone);
  });
}

for (const [language, locale] of [
  ['ja', 'ja_JP.UTF-8'], ['en', 'en_US.UTF-8'], ['zh', 'zh_CN.UTF-8'],
]) {
  test(`Language ${language} produces only the four runtime environment variables`, () => {
    assert.deepEqual(profileEnvironment(profile({ language })), {
      TZ: 'Asia/Tokyo', LANG: locale, LC_ALL: locale, LC_MESSAGES: locale,
    });
  });
}

test('Validation and environment conversion preserve input and parent process environment', () => {
  const input = Object.freeze(profile());
  const before = parentRuntimeEnvironment();
  validateRuntimeProfile(input);
  const environment = profileEnvironment(input);
  assert.deepEqual(input, japan);
  assert.deepEqual(parentRuntimeEnvironment(), before);
  assert.deepEqual(Object.keys(environment).sort(), [...runtimeEnvironmentKeys].sort());
});

const childProbe = `
  const instant = new Date('2026-01-15T00:00:00.000Z');
  const resolved = new Intl.DateTimeFormat().resolvedOptions();
  process.stdout.write(JSON.stringify({
    timeZone: resolved.timeZone,
    locale: resolved.locale,
    localHour: instant.getHours(),
    offsetMinutes: instant.getTimezoneOffset(),
    environment: Object.fromEntries(['TZ', 'LANG', 'LC_ALL', 'LC_MESSAGES'].map(key => [key, process.env[key]]))
  }));
`;

for (const [language, timeZone, localHour, offsetMinutes] of [
  ['ja', 'Asia/Tokyo', 9, -540],
  ['en', 'America/New_York', 19, 300],
  ['zh', 'Asia/Shanghai', 8, -480],
]) {
  test(`A real Node child applies ${language} locale and ${timeZone} before startup`, () => {
    const before = parentRuntimeEnvironment();
    const environment = profileEnvironment(profile({ language, timeZone }));
    const result = spawnSync(process.execPath, ['--input-type=module', '--eval', childProbe], {
      env: { ...process.env, ...environment }, encoding: 'utf8', timeout: 10000, maxBuffer: 4096,
    });
    assert.equal(result.error, undefined, 'The offline child must start successfully.');
    assert.equal(result.status, 0, 'The offline child must exit successfully.');
    assert.equal(result.stderr, '');
    const observed = JSON.parse(result.stdout);
    assert.equal(observed.timeZone, timeZone);
    assert.match(observed.locale, new RegExp(`^${language}(?:-|$)`));
    assert.equal(observed.localHour, localHour);
    assert.equal(observed.offsetMinutes, offsetMinutes);
    assert.deepEqual(observed.environment, environment);
    assert.deepEqual(parentRuntimeEnvironment(), before);
  });
}
