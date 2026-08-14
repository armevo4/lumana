// Proves the zero-downtime claim.
//
// The brief says "strive to zero downtime". Striving is not evidence — this is. It holds
// constant load on the API for six minutes, which spans at least five credential
// rotations at the CronJob's one-minute schedule, and fails the run if a single request
// returns anything other than 2xx.
//
// A clean run with no rotations would prove nothing, so a second scenario watches
// /rotation and records how many rotations actually happened. Both thresholds must pass:
// zero failures AND at least five observed rotations.
//
//   make loadtest
//   k6 run -e BASE_URL=http://lumana.localtest.me:8080 load/rotation-test.js

import http from "k6/http";
import { check, sleep } from "k6";
import { Counter, Gauge } from "k6/metrics";

const BASE_URL = __ENV.BASE_URL || "http://lumana.localtest.me:8080";
const DURATION = __ENV.DURATION || "6m";

const rotationsObserved = new Gauge("rotations_observed");
const credentialSwitches = new Counter("credential_switches");

export const options = {
  scenarios: {
    // The actual load. Every request reads from MongoDB and writes a history record,
    // so the database is genuinely on the hot path — a broken connection cannot hide.
    traffic: {
      executor: "constant-vus",
      vus: 10,
      duration: DURATION,
      exec: "search",
    },
    // Observer. Confirms rotations really occurred during the run.
    watcher: {
      executor: "constant-vus",
      vus: 1,
      duration: DURATION,
      exec: "watchRotations",
    },
  },
  thresholds: {
    // The headline claim. Not "low error rate" — zero.
    http_req_failed: ["rate==0"],
    http_req_duration: ["p(95)<1500"],
    // Guards against a vacuously green run where nothing rotated.
    rotations_observed: ["value>=5"],
  },
};

// A small fixed set, so most requests are cache hits against MongoDB rather than calls
// out to TMDB. The point is to exercise the database connection, not the upstream API.
const QUERIES = [
  "inception",
  "the matrix",
  "blade runner",
  "arrival",
  "interstellar",
  "dune",
];

export function search() {
  const query = QUERIES[Math.floor(Math.random() * QUERIES.length)];
  const res = http.get(`${BASE_URL}/search?q=${encodeURIComponent(query)}`, {
    tags: { name: "search" },
  });

  check(res, {
    "search returned 200": (r) => r.status === 200,
    "search returned results": (r) => {
      try {
        return JSON.parse(r.body).total_results > 0;
      } catch (e) {
        return false;
      }
    },
  });

  sleep(0.5);
}

let lastUsername = null;

export function watchRotations() {
  const res = http.get(`${BASE_URL}/rotation`, { tags: { name: "rotation" } });

  if (res.status === 200) {
    try {
      const body = JSON.parse(res.body);
      rotationsObserved.add(body.rotations_applied);

      if (lastUsername !== null && body.active_username !== lastUsername) {
        credentialSwitches.add(1);
        console.log(
          `credential switched: ${lastUsername} -> ${body.active_username} ` +
            `(rotation #${body.rotations_applied})`,
        );
      }
      lastUsername = body.active_username;
    } catch (e) {
      // Body was not JSON; the request itself still counts toward http_req_failed.
    }
  }

  sleep(3);
}
