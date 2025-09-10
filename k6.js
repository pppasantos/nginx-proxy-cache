import http from 'k6/http';
import { check, sleep } from 'k6';

export const options = {
  vus: 1,
  iterations: 1652,
};

const ids = Array.from({ length: 826 }, (_, i) => i + 1);
let current = 0;

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

  check(resImg, {
    'status is 200 (img)': (r) => r.status === 200,
    'image is not empty': (r) => r.body && r.body.length > 0,
    'X-Cache is defined (img)': (r) => r.headers['X-Cache'] !== undefined,
  });
}

