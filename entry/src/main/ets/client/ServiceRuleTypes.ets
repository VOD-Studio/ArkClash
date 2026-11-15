import { ProbeRequestOptions, ProbeResponse } from './ProbeProtocol';

export type ServiceAvailability = 'unknown' | 'available' | 'restricted' | 'unavailable' | 'disallowed-isp' |
  'blocked' | 'unsupported-region' | 'originals-only' | 'coming-soon' | 'timeout' | 'failed';

export interface ServiceProbeReply extends ProbeResponse {
  failure: '' | 'timeout' | 'failed';
}

export interface ServiceProbeSession {
  send(options: ProbeRequestOptions): Promise<ServiceProbeReply>;
}

export interface ServiceRuleResult {
  availability: ServiceAvailability;
  region: string;
  delay: number;
  httpCode: number;
}
