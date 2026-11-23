function normalizeIP(value) {
  const address = value.trim();
  if (!/^[0-9a-f:.]+$/i.test(address)) { return ''; }
  try {
    return new URL(address.includes(':') ? `http://[${address}]` : `http://${address}`).hostname;
  } catch {
    return '';
  }
}

async function sample(config) {
  const url = new URL(config.url);
  url.searchParams.set('arkclash_bench', crypto.randomUUID());
  const abort = new AbortController();
  const deadline = setTimeout(() => abort.abort(), config.timeout * 1000);
  const started = performance.now();
  const row = { status: 'request_failed', started_ms: performance.timeOrigin + started, http_status: 0 };
  try {
    const response = await fetch(url, {
      cache: 'no-store', credentials: 'omit', redirect: 'error', referrerPolicy: 'no-referrer', signal: abort.signal
    });
    row.http_status = response.status;
    const address = normalizeIP(await response.text());
    row.complete_ms = performance.now() - started;
    let timing = performance.getEntriesByName(url.href, 'resource').pop();
    if (timing === undefined) {
      await new Promise(resolve => setTimeout(resolve, 0));
      timing = performance.getEntriesByName(url.href, 'resource').pop();
    }
    if (response.status !== 200) {
      row.status = 'unexpected_http_status';
    } else if (!address) {
      row.status = 'invalid_exit_response';
    } else if (!timing?.responseStart || !timing.transferSize) {
      row.status = 'missing_resource_timing';
    } else if (timing.nextHopProtocol !== 'http/1.1' || timing.connectEnd <= timing.connectStart ||
      !timing.secureConnectionStart || timing.secureConnectionStart < timing.connectStart ||
      timing.connectEnd < timing.secureConnectionStart) {
      row.status = 'no_new_tls_connection';
    } else {
      row.dns_ms = timing.domainLookupEnd - timing.domainLookupStart;
      row.tcp_ms = timing.secureConnectionStart - timing.connectStart;
      row.tls_ms = timing.connectEnd - timing.secureConnectionStart;
      row.first_byte_ms = timing.responseStart - timing.startTime;
      row.status = address === normalizeIP(config.exit_ip) ? 'ok' : 'other_exit';
    }
  } catch {
    row.status = abort.signal.aborted ? 'timeout' : 'request_failed';
  } finally {
    clearTimeout(deadline);
  }
  row.complete_ms ??= performance.now() - started;
  return row;
}

const config = await (await fetch('config', { cache: 'no-store' })).json();
for (let index = 0; index < config.count; index++) {
  performance.clearResourceTimings();
  const row = await sample(config);
  const delivered = await fetch('sample', { method: 'POST', body: JSON.stringify(row) });
  if (!delivered.ok) { throw new Error('result rejected'); }
}
document.body.textContent = 'ArkClash 采样完成';
