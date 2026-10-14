export class TranslationError extends Error {
  constructor(code, message, { retryable = false, details = {} } = {}) {
    super(message);
    this.name = 'TranslationError';
    this.code = code;
    this.retryable = retryable;
    this.details = Object.freeze({ ...details });
  }
}

export function fail(code, message, details) {
  throw new TranslationError(code, message, { details });
}
