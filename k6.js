import http from 'k6/http';
import { check, sleep } from 'k6';

export let options = {
  vus: 20,                // 20 usuários virtuais simultâneos
  duration: '30s',        // durante 30 segundos
  thresholds: {
    http_req_duration: ['p(95)<500'], // 95% das requisições abaixo de 500ms
    http_req_failed: ['rate<0.01'],   // menos de 1% de falhas
  },
};

const BASE_URL = 'http://localhost:8889';
const HOST_HEADER = 'rickandmortyapi.com';

export default function () {
  const id = Math.floor(Math.random() * 700) + 1; // IDs entre 1 e 700
  const res = http.get(`${BASE_URL}/api/character/${id}`, {
    headers: {
      'Host': HOST_HEADER,
      'Accept': 'application/json',
    },
    tags: { character_id: id.toString() },
  });

  check(res, {
    'status is 200': (r) => r.status === 200,
    'body is not empty': (r) => r.body && r.body.length > 0,
  });

  sleep(0.1); // pequeno delay para evitar DDoS no backend
}
