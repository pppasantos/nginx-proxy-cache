import http from 'k6/http';
import { check, group, sleep } from 'k6';

export const options = {
  vus: 1,
  iterations: 50,
};

const ids = Array.from({ length: 100 }, (_, i) => i + 1);
let current = 0;

function testCacheInvalidation(baseURL, hostHeader, id) {
  const uri = `/api/character/${id}?k6_invalidation=${__VU}_${__ITER}_${Date.now()}`;
  const requestOptions = {
    headers: Object.assign({}, hostHeader, {
      Accept: 'application/json',
    }),
  };
  const endpoint = `${baseURL}/cache_invalidate`;
  const jsonOptions = {
    headers: Object.assign({}, hostHeader, {
      'Content-Type': 'application/json',
    }),
  };
  const badRequestOptions = Object.assign({}, jsonOptions, {
    responseCallback: http.expectedStatuses(400),
  });

  group('cache invalidation endpoint', () => {
    const warmResponse = http.get(`${baseURL}${uri}`, requestOptions);
    check(warmResponse, {
      'invalidation setup returns 200': (r) => r.status === 200,
      'invalidation setup populates cache': (r) => r.headers['X-Cache'] === 'MISS',
    });

    const hitResponse = http.get(`${baseURL}${uri}`, requestOptions);
    check(hitResponse, {
      'same request is served from cache': (r) => r.headers['X-Cache'] === 'HIT',
    });

    const descriptor = {
      requests: [{
        scheme: 'http',
        method: 'GET',
        uri,
        headers: {},
        cache_headers: '',
        cache_use_body_in_key: true,
      }],
    };
    const invalidateByRequest = http.post(endpoint, JSON.stringify(descriptor), jsonOptions);
    let derivedKey;
    if (invalidateByRequest.status === 200) {
      const payload = invalidateByRequest.json();
      derivedKey = payload.derived_keys && payload.derived_keys[0];
      check(payload, {
        'request descriptor deletes one cached key': (body) => body.deleted === 1,
        'request descriptor returns a derived key': (body) =>
          Array.isArray(body.derived_keys) && body.derived_keys.length === 1,
      });
    }
    check(invalidateByRequest, {
      'request descriptor is accepted': (r) => r.status === 200,
    });
    console.info(`🧹 Invalidate by request: status=${invalidateByRequest.status}, body=${invalidateByRequest.body}`);

    const repeatedInvalidation = http.post(endpoint, JSON.stringify(descriptor), jsonOptions);
    let repeatedPayload = {};
    if (repeatedInvalidation.status === 200) {
      repeatedPayload = repeatedInvalidation.json();
    }
    check(repeatedInvalidation, {
      'repeated invalidation is accepted': (r) => r.status === 200,
    });
    check(repeatedPayload, {
      'repeated invalidation deletes zero keys': (body) => body.deleted === 0,
    });

    const missAfterInvalidation = http.get(`${baseURL}${uri}`, requestOptions);
    check(missAfterInvalidation, {
      'request after invalidation is a MISS': (r) =>
        r.status === 200 && r.headers['X-Cache'] === 'MISS',
    });

    if (derivedKey) {
      const invalidateByKey = http.post(
        endpoint,
        JSON.stringify({ keys: [derivedKey] }),
        jsonOptions
      );
      let keyPayload = {};
      if (invalidateByKey.status === 200) {
        keyPayload = invalidateByKey.json();
      }
      check(invalidateByKey, {
        'direct key invalidation is accepted': (r) => r.status === 200,
      });
      check(keyPayload, {
        'direct key invalidation removes the repopulated entry': (body) =>
          body.deleted === 1
          && Array.isArray(body.removed_keys)
          && body.removed_keys[0] === derivedKey,
      });
      console.info(`🧹 Invalidate by key: status=${invalidateByKey.status}, body=${invalidateByKey.body}`);
    }

    const wrongMethod = http.get(endpoint, {
      headers: hostHeader,
      responseCallback: http.expectedStatuses(405),
    });
    check(wrongMethod, {
      'non-POST method is rejected': (r) => r.status === 405,
    });

    const missingBody = http.post(endpoint, null, badRequestOptions);
    check(missingBody, {
      'missing payload is rejected': (r) => r.status === 400,
    });

    const invalidJson = http.post(endpoint, '{', badRequestOptions);
    check(invalidJson, {
      'invalid JSON is rejected': (r) => r.status === 400,
    });

    const emptyPayload = http.post(endpoint, '{}', badRequestOptions);
    check(emptyPayload, {
      'payload without keys or requests is rejected': (r) => r.status === 400,
    });
  });
}

export default function () {
  const id = ids[current % ids.length];
  current++;

  const baseURL = 'http://nginx:8889';
  const hostHeader = { Host: 'rickandmortyapi.com' };

  // JSON request
  let resJson = http.get(`${baseURL}/api/character/${id}`, {
    headers: Object.assign({}, hostHeader, {
      Accept: 'application/json',
    }),
  });

  console.info(
    `🟢 JSON ID: ${id} - Status: ${resJson.status} - X-Cache: ${resJson.headers['X-Cache']}`
  );
  console.log('🟢 JSON Headers:', JSON.stringify(resJson.headers, null, 2));
  console.log('🟢 JSON Body:', resJson.body ? resJson.body.substring(0, 300) + '...' : '(empty)');

  check(resJson, {
    'status is 200': (r) => r.status === 200,
    'body is not empty': (r) => r.body && r.body.length > 0,
    'X-Cache is defined (json)': (r) => r.headers['X-Cache'] !== undefined,
  });

  // Image request
  let resImg = http.get(`${baseURL}/api/character/avatar/${id}.jpeg`, {
    headers: Object.assign({}, hostHeader, {
      Accept: 'image/jpeg',
    }),
  });

  console.info(
    `🟡 IMG ID: ${id} - Status: ${resImg.status} - X-Cache: ${resImg.headers['X-Cache']}`
  );
  console.log('🟡 IMG Headers:', JSON.stringify(resImg.headers, null, 2));
  console.log(
    `🟡 IMG Body size: ${resImg.body ? resImg.body.length : 0} bytes`
  );

  check(resImg, {
    'status is 200 (img)': (r) => r.status === 200,
    'image is not empty': (r) => r.body && r.body.length > 0,
    'X-Cache is defined (img)': (r) => r.headers['X-Cache'] !== undefined,
  });

  if (__ITER === 0) {
    testCacheInvalidation(baseURL, hostHeader, id);
  }

  sleep(1);
}
