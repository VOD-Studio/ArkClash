import { BusinessError } from '@kit.BasicServicesKit';
import { url } from '@kit.ArkTS';
import { http } from '@kit.NetworkKit';
import { ProbeMethod, ProbeRequestOptions, ProbeResponse, RoutedProbeError } from './ProbeProtocol';
import { ProbeResponseBody } from './ProbeResponseBody';

function headerValue(header: Record<string, string>, name: string): string {
  for (const key of Object.keys(header)) {
    if (key.toLowerCase() === name && typeof header[key] === 'string') { return header[key]; }
  }
  return '';
}

function isRedirect(status: number): boolean {
  return status === 301 || status === 302 || status === 303 || status === 307 || status === 308;
}

function checkedUrl(address: string, base?: string): url.URL {
  const parsed = url.URL.parseURL(address, base);
  if ((parsed.protocol !== 'http:' && parsed.protocol !== 'https:') || parsed.hostname === '' ||
    parsed.href.length > 2048 || parsed.username !== '' || parsed.password !== '') {
    throw new RoutedProbeError('invalidResponse');
  }
  return parsed;
}

export class DirectProbeRequest {
  private cancelled: boolean = false;
  private cancelCurrent?: () => void;

  cancel(): void {
    this.cancelled = true;
    this.cancelCurrent?.();
  }

  async run(options: ProbeRequestOptions, timeoutMs: number): Promise<ProbeResponse> {
    if (options.url.length > 2048) { throw new RoutedProbeError('invalidResponse'); }
    checkedUrl(options.url);
    const started = Date.now();
    const deadline = started + timeoutMs;
    let current = options;
    for (let redirects = 0; redirects < 10; redirects++) {
      if (this.cancelled) { throw new RoutedProbeError('cancelled'); }
      const remaining = deadline - Date.now();
      if (remaining <= 0) { throw new RoutedProbeError('timeout'); }
      const sentAt = Date.now();
      const response = await this.requestOnce(current, remaining);
      response.delay += sentAt - started;
      if (current.noRedirect || !isRedirect(response.status) || response.location === '') { return response; }
      if (redirects === 9) { throw new RoutedProbeError('transport'); }
      const next = checkedUrl(response.location, current.url);
      const origin = checkedUrl(current.url);
      const dropBody = response.status !== 307 && response.status !== 308 && current.method === 'POST';
      if (!dropBody && current.body !== undefined && current.body !== '' && next.origin !== origin.origin) {
        return response;
      }
      const method: ProbeMethod = dropBody ? 'GET' : current.method;
      const previousHeaders: Record<string, string> = current.headers ?? {};
      const headers: Record<string, string> = {};
      for (const name of Object.keys(previousHeaders)) {
        const lower = name.toLowerCase();
        if ((lower === 'authorization' && next.origin !== origin.origin) ||
          (lower === 'content-type' && dropBody)) { continue; }
        headers[name] = previousHeaders[name];
      }
      current = { url: next.href, method: method, headers: headers, body: dropBody ? undefined : current.body,
        bodyMode: current.bodyMode, scanPattern: current.scanPattern, noRedirect: current.noRedirect };
    }
    throw new RoutedProbeError('transport');
  }

  private requestOnce(options: ProbeRequestOptions, timeoutMs: number): Promise<ProbeResponse> {
    const body = new ProbeResponseBody(options.method === 'HEAD' ? 'none' : options.bodyMode, options.scanPattern);
    const request = http.createHttp();
    const header: Record<string, string> = options.headers ?? {};
    return new Promise<ProbeResponse>((resolve, reject): void => {
      const started = Date.now();
      let status = 0;
      let location = '';
      let delay = 0;
      let settled = false;
      let timer = -1;
      let received = 0;
      let collected = options.bodyMode === 'none' || options.method === 'HEAD';
      let headersSeen = false;
      const finish = (failure?: RoutedProbeError): void => {
        if (settled) { return; }
        let content = '';
        if (failure === undefined && status >= 100 && status <= 599) {
          try { content = body.text(); }
          catch (error) { failure = new RoutedProbeError('invalidResponse'); }
        }
        settled = true;
        clearTimeout(timer);
        this.cancelCurrent = undefined;
        request.off('headersReceive');
        request.off('dataReceive');
        request.off('dataEnd');
        request.destroy();
        if (failure !== undefined) { reject(failure); }
        else if (status < 100 || status > 599) { reject(new RoutedProbeError('invalidResponse')); }
        else { resolve({ status: status, body: content, url: options.url, location: location, delay: delay }); }
      };
      this.cancelCurrent = (): void => finish(new RoutedProbeError('cancelled'));
      timer = setTimeout((): void => finish(new RoutedProbeError('timeout')), timeoutMs);
      request.on('headersReceive', (header: Object): void => {
        if (settled) { return; }
        let fields: Record<string, string>;
        try {
          fields = typeof header === 'string' ? JSON.parse(header) as Record<string, string> :
            header as Record<string, string>;
        } catch (error) {
          finish(new RoutedProbeError('invalidResponse'));
          return;
        }
        location = headerValue(fields, 'location');
        if (!headersSeen) { delay = Date.now() - started; headersSeen = true; }
        const line = headerValue(fields, 'status-line');
        const code = new RegExp('^HTTP/\\S+\\s+(\\d{3})(?:\\s|$)').exec(line);
        if (code === null || Number(code[1]) < 200) { return; }
        status = Number(code[1]);
        delay = Date.now() - started;
        if (collected || (!options.noRedirect && isRedirect(status) && location !== '')) { finish(); }
      });
      request.on('dataReceive', (data: ArrayBuffer): void => {
        if (settled) { return; }
        received += data.byteLength;
        if (received > 8 * 1024 * 1024) { finish(new RoutedProbeError('invalidResponse')); return; }
        try {
          if (!collected) { collected = body.append(data); }
          if (collected && status >= 200) { finish(); }
        }
        catch (error) {
          finish(error instanceof RoutedProbeError ? error : new RoutedProbeError('invalidResponse'));
        }
      });
      request.on('dataEnd', (): void => { if (status >= 200) { finish(); } });
      request.requestInStream(options.url, {
        method: options.method === 'POST' ? http.RequestMethod.POST :
          options.method === 'HEAD' ? http.RequestMethod.HEAD : http.RequestMethod.GET,
        header: header,
        extraData: options.method === 'POST' ? options.body : undefined,
        usingProxy: false,
        usingCache: false,
        connectTimeout: timeoutMs,
        readTimeout: timeoutMs,
        maxRedirects: 0
      }).then((code: number): void => {
        if (settled) { return; }
        if (status === 0) { status = code; }
        if (!headersSeen) { delay = Date.now() - started; }
        finish();
      }).catch((error: BusinessError): void => {
        finish(new RoutedProbeError(this.cancelled ? 'cancelled' : error.code === 2300028 ? 'timeout' : 'transport'));
      });
    });
  }
}
