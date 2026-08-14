# Load test results

Run against the dev cluster (kind), six minutes of constant load spanning eight credential
rotations.

```
k6 run -e BASE_URL=http://lumana.localtest.me:8080 load/rotation-test.js

     ✓ search returned 200
     ✓ search returned results

     checks.........................: 100.00%  13892 out of 13892
     credential_switches............: 4
   ✓ http_req_failed................: 0.00%    0 out of 7066
   ✓ http_req_duration..............: avg=17.24ms  med=13.69ms  p(95)=34.83ms
   ✓ rotations_observed.............: 8         (threshold: >=5)
     http_reqs......................: 7066      19.59/s
     iterations.....................: 7066      0 interrupted

     running (6m00.6s), 00/11 VUs, 7066 complete and 0 interrupted iterations
     traffic ✓ [ 100% ] 10 VUs  6m0s
     watcher ✓ [ 100% ] 1 VUs   6m0s
```

## What this proves

**7,066 requests, zero failures, across 8 credential rotations.** Every request read from
MongoDB and most wrote to it, so the rotated connection was genuinely exercised rather than
bypassed by a cache.

All three thresholds passed:

| Threshold | Meaning |
|---|---|
| `http_req_failed: rate==0` | Not a low error rate — **zero** failed requests |
| `rotations_observed: value>=5` | Guards against a vacuously green run where nothing rotated |
| `http_req_duration: p(95)<1500` | Rotation did not degrade latency |

The second threshold matters as much as the first. Without it, a test that simply never
rotated would pass with a perfect score and prove nothing.

## Reproducing

```bash
make loadtest
```

Takes six minutes. The API must be reachable at `http://lumana.localtest.me:8080` — bring
it up with `make dev` first.
