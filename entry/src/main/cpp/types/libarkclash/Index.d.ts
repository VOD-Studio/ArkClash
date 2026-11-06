/** Starts the core; rejects with the core's error message. Options: see core/lib.go startOptions. */
export const start: (optionsJson: string) => Promise<void>;
export const stop: () => Promise<void>;
export const version: () => string;
