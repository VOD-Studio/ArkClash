export type ProbeMethod = 'GET' | 'HEAD' | 'POST';
export type ProbeBodyMode = 'none' | 'small' | 'html' | 'scan' | 'json';

export interface ProbeRequestOptions {
  url: string;
  method: ProbeMethod;
  bodyMode: ProbeBodyMode;
  headers?: Record<string, string>;
  body?: string;
  noRedirect?: boolean;
  scanPattern?: string;
}

export interface ProbeResponse {
  status: number;
  body: string;
  url: string;
  location: string;
  delay: number;
}

export type RoutedProbeFailure = 'cancelled' | 'capacity' | 'routeChanged' | 'timeout' | 'transport' | 'controller' |
  'invalidResponse';

export class RoutedProbeError extends Error {
  reason: RoutedProbeFailure;
  controlStatus: number;

  constructor(reason: RoutedProbeFailure, controlStatus: number = 0) {
    super('probe request failed');
    this.reason = reason;
    this.controlStatus = controlStatus;
  }
}
