// k6 load profile: realistic mix (90% quote reads, 8% blotter, 2% executions),
// ramping arrival rate (open model: load does not slow down when the system
// does). Thresholds are the SLOs, so a breach fails the run.
import http from 'k6/http';
import { check, sleep } from 'k6';

const TARGET = __ENV.TARGET;
// Per load generator. Default 4 req/s (spike 8) keeps one source IP under the
// WAF limit of 2000 requests / 5 min; scale the TOTAL load with more runners.
const PEAK = Number(__ENV.PEAK_RPS || 4);
const PAIRS = ['EURUSD', 'EURGBP', 'EURJPY', 'EURCHF'];

export const options = {
  scenarios: {
    traffic: {
      executor: 'ramping-arrival-rate',
      startRate: 1, timeUnit: '1s', preAllocatedVUs: 200, maxVUs: 1500,
      stages: [
        { target: PEAK / 4, duration: '2m' },  // warm-up
        { target: PEAK, duration: '5m' },      // ramp: watch ECS + Aurora scale out
        { target: PEAK, duration: '5m' },      // sustain
        { target: PEAK * 2, duration: '2m' },  // spike x2
        { target: 0, duration: '2m' },         // recovery / scale-in
      ],
    },
  },
  thresholds: {
    'http_req_failed{kind:api}': ['rate<0.001'],             // availability SLO 99.9%
    'http_req_duration{kind:quote}': ['p(95)<300', 'p(99)<800'],
    'http_req_duration{kind:execute}': ['p(95)<500'],
    checks: ['rate>0.999'],
  },
};

const sessions = {};
function token() {
  const s = sessions[__VU];
  if (s && s.exp > Date.now() + 30000) return s.token;
  const headers = s ? { Authorization: `Bearer ${s.token}` } : {};
  const r = http.post(`${TARGET}/x/s`, null, { headers, tags: { kind: 'session' } });
  const body = r.json();
  sessions[__VU] = { token: body.token, exp: Date.now() + body.expires_in * 1000 };
  return body.token;
}

export default function () {
  const auth = { Authorization: `Bearer ${token()}` };
  const pair = PAIRS[Math.floor(Math.random() * PAIRS.length)];
  const roll = Math.random();
  if (roll < 0.90) {
    const r = http.get(`${TARGET}/x/q?p=${pair}`, { headers: auth, tags: { kind: 'quote' } });
    check(r, { 'quote 200': (x) => x.status === 200, 'bid<ask': (x) => x.json('bid') < x.json('ask') });
  } else if (roll < 0.98) {
    const r = http.get(`${TARGET}/x/d`, { headers: auth, tags: { kind: 'api' } });
    check(r, { 'blotter 200': (x) => x.status === 200 });
  } else {
    const q = http.get(`${TARGET}/x/q?p=${pair}`, { headers: auth, tags: { kind: 'quote' } }).json();
    const key = crypto.randomUUID(); // WebCrypto global, no remote import
    const body = JSON.stringify({ quote: q.token, side: Math.random() < 0.5 ? 'BUY' : 'SELL', notional: 100000 });
    const params = { headers: Object.assign({ 'Content-Type': 'application/json', 'Idempotency-Key': key }, auth), tags: { kind: 'execute' } };
    const r1 = http.post(`${TARGET}/x/d`, body, params);
    // replay with the same key: must return the SAME deal, never a duplicate
    const r2 = http.post(`${TARGET}/x/d`, body, params);
    check(r1, { 'execute 201': (x) => x.status === 201 });
    check(r2, { 'replay idempotent': (x) => x.status === 200 && x.json('id') === r1.json('id') });
  }
  sleep(0.1);
}
