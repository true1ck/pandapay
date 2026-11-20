'use strict';

// Shares work between identical reads that pile up, without ever answering a request with data read before it
// arrived. Plain single-flight would hand a request that comes in mid-run the answer of a run that started earlier,
// which can miss a write the phone committed just before asking (an SMS upload, then a wallet refresh).
//
// Per key there is at most one run going and at most one run waiting:
//   - no run going: start one;
//   - a run going: wait for it to end, then share ONE follow-up run with every other request that arrived meanwhile.
// The follow-up starts after all of its requests arrived, so each answer includes every write committed before its
// request was sent. Nothing is cached: once a key has no run going or waiting, the next request runs on its own.

function createRequestCoalescer() {
  const lanes = new Map(); // key -> { next: { promise, begin } | null }

  function start(key, lane, work) {
    const promise = Promise.resolve().then(work);
    const settle = () => {
      const next = lane.next;
      if (next) {
        lane.next = null;
        next.begin();
      } else {
        lanes.delete(key);
      }
    };
    promise.then(settle, settle);
    return promise;
  }

  return {
    run(key, work) {
      const lane = lanes.get(key);
      if (!lane) {
        const fresh = { next: null };
        lanes.set(key, fresh);
        return start(key, fresh, work);
      }
      if (lane.next) return lane.next.promise;
      let begin;
      const promise = new Promise((resolve, reject) => {
        begin = () => start(key, lane, work).then(resolve, reject);
      });
      lane.next = { promise, begin };
      return promise;
    },
    get size() { return lanes.size; },
  };
}

module.exports = { createRequestCoalescer };
