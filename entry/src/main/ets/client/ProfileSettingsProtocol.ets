export interface VersionedProfileSettings {
  revision: string;
}

export interface ProfileSettingsRequest<T extends VersionedProfileSettings> {
  bootId: string;
  expectedRevision: string;
  settings: T;
}

export function profileSettingsRequestJson<T extends VersionedProfileSettings>(bootId: string, expectedRevision: string,
  settings: T): string {
  const request: ProfileSettingsRequest<T> = { bootId: bootId, expectedRevision: expectedRevision, settings: settings };
  return JSON.stringify(request);
}
