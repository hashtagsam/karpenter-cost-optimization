// k6 load profile: ramp up -> sustained peak -> ramp down -> idle tail.
// The idle tail is deliberate: it lets you watch HPA scale pods in and
// Karpenter consolidate the now-empty nodes, which is where the savings
// show up.
import http from 'k6/http';
import { check } from 'k6';

const BASE = __ENV.TARGET_URL || 'http://podinfo.demo.svc.cluster.local:9898';

export const options = {
    scenarios: {
        traffic: {
            executor: 'ramping-vus',
            startVUs: 0,
            stages: [
                { duration: '2m', target: 50 },   // warm-up
                { duration: '3m', target: 300 },  // ramp to peak
                { duration: '8m', target: 300 },  // sustained peak -> nodes scale out
                { duration: '2m', target: 0 },    // traffic drops away
            ],
            gracefulRampDown: '30s',
        },
    },
    // The test FAILS if reliability degrades - cost savings that hurt users
    // are not savings. These hold even while Karpenter replaces nodes.
    thresholds: {
        http_req_failed: ['rate<0.01'],
        http_req_duration: ['p(95)<500'],
    },
};

export default function () {
    // A mix of cheap and CPU-heavier endpoints
    const res = http.get(`${BASE}/`);
    check(res, { 'status is 200': (r) => r.status === 200 });
    http.post(`${BASE}/token`);
}