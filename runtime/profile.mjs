// App-owned process locale settings. This module never reads or mutates the
// parent environment, and its output contains no credentials or host paths.
export const RUNTIME_PROFILE_SCHEMA = 'app-runtime-profile/v1';
export const RUNTIME_ERROR_CODES = Object.freeze([
  'RUNTIME_PROFILE_REQUIRED', 'RUNTIME_PROFILE_INVALID',
]);
export const DEFAULT_RUNTIME_PROFILE = Object.freeze({
  schema: RUNTIME_PROFILE_SCHEMA, timeZone: 'Asia/Tokyo', language: 'ja',
});

export class RuntimeProfileError extends Error {
  constructor(code) {
    super(RUNTIME_ERROR_CODES.includes(code) ? code : 'RUNTIME_PROFILE_INVALID');
    this.name = 'RuntimeProfileError';
    this.code = this.message;
  }
}

const LOCALES = Object.freeze({ ja: 'ja_JP.UTF-8', en: 'en_US.UTF-8', zh: 'zh_CN.UTF-8' });
// Foundation on the supported macOS runtime lists these IANA names, while the
// bundled Node ICU reports older canonical names or omits backward links from
// supportedValuesOf(). Retain the user's spelling; Intl still validates every
// request. The App's Swift validator is the narrower settings entry point.
const FOUNDATION_IANA_NAMES = [
  'Africa/Asmara', 'America/Argentina/Buenos_Aires', 'America/Argentina/Catamarca',
  'America/Argentina/Cordoba', 'America/Argentina/Jujuy', 'America/Argentina/Mendoza',
  'America/Atikokan', 'America/Indiana/Indianapolis', 'America/Kentucky/Louisville',
  'America/Montreal', 'America/Nipigon', 'America/Nuuk', 'America/Pangnirtung',
  'America/Rainy_River', 'America/Santa_Isabel', 'America/Shiprock', 'America/Thunder_Bay',
  'America/Yellowknife', 'Antarctica/South_Pole', 'Asia/Choibalsan', 'Asia/Chongqing',
  'Asia/Harbin', 'Asia/Ho_Chi_Minh', 'Asia/Kashgar', 'Asia/Kathmandu', 'Asia/Yangon',
  'Atlantic/Faroe', 'Australia/Currie', 'Europe/Kyiv', 'Europe/Uzhgorod',
  'Europe/Zaporozhye', 'Pacific/Chuuk', 'Pacific/Johnston', 'Pacific/Kanton', 'Pacific/Pohnpei',
];
const TIME_ZONES = new Set(['UTC', ...Intl.supportedValuesOf('timeZone'), ...FOUNDATION_IANA_NAMES]);

export function validateRuntimeProfile(profile) {
  if (profile === undefined || profile === null) throw new RuntimeProfileError('RUNTIME_PROFILE_REQUIRED');
  if (typeof profile !== 'object' || Array.isArray(profile) || Object.keys(profile).length !== 3 ||
      Object.keys(profile).some(key => !['schema', 'timeZone', 'language'].includes(key)) ||
      profile.schema !== RUNTIME_PROFILE_SCHEMA || typeof profile.language !== 'string' || !Object.hasOwn(LOCALES, profile.language) ||
      typeof profile.timeZone !== 'string' || profile.timeZone.length > 128 ||
      !/^(?:UTC|[A-Za-z][A-Za-z0-9._+-]*(?:\/[A-Za-z0-9._+-]+)+)$/.test(profile.timeZone) ||
      !TIME_ZONES.has(profile.timeZone)) {
    throw new RuntimeProfileError('RUNTIME_PROFILE_INVALID');
  }
  try { new Intl.DateTimeFormat('en-US', { timeZone: profile.timeZone }).format(0); }
  catch { throw new RuntimeProfileError('RUNTIME_PROFILE_INVALID'); }
  return Object.freeze({ schema: RUNTIME_PROFILE_SCHEMA, timeZone: profile.timeZone, language: profile.language });
}

export function profileEnvironment(profile) {
  const validated = validateRuntimeProfile(profile);
  const locale = LOCALES[validated.language];
  return Object.freeze({ TZ: validated.timeZone, LANG: locale, LC_ALL: locale, LC_MESSAGES: locale });
}
