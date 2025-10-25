import http from 'k6/http';
import { check, sleep } from 'k6';
import { abort } from 'k6';

export const options = {
  vus: 1,
  iterations: 1652,
  // Adiciona thresholds para falhas
  thresholds: {
    http_req_failed: ['rate<0.01'], // Aborta se mais de 1% das requisições falharem
    http_req_duration: ['p(95)<5000'], // Aborta se 95% das requisições demorarem mais de 5s
  },
};

const ids = Array.from({ length: 826 }, (_, i) => i + 1);
let current = 0;

// Função para verificar se é um erro crítico que deve encerrar o teste
function isCriticalError(error) {
  const criticalErrors = [
    'no route to host',
    'ECONNREFUSED',
    'ETIMEDOUT',
    'ENOTFOUND',
    'ECONNRESET'
  ];
  
  return criticalErrors.some(criticalError => 
    error && error.includes(criticalError)
  );
}

export default function () {
  const id = ids[current % ids.length];
  current++;

  const baseURL = 'http://nginx:8889';
  const hostHeader = { Host: 'rickandmortyapi.com' };

  // JSON request
  let resJson;
  try {
    resJson = http.get(`${baseURL}/api/character/${id}`, {
      headers: Object.assign({}, hostHeader, {
        Accept: 'application/json',
      }),
      timeout: '30s', // Adiciona timeout
    });

    console.info(
      `🟢 JSON ID: ${id} - Status: ${resJson.status} - X-Cache: ${resJson.headers['X-Cache']}`
    );

    // Verifica se houve erro crítico na resposta
    if (resJson.error && isCriticalError(resJson.error)) {
      console.error(`❌ Erro crítico detectado: ${resJson.error}`);
      abort('Teste abortado devido a erro crítico de conexão');
    }

    const jsonChecks = check(resJson, {
      'status is 200': (r) => r.status === 200,
      'body is not empty': (r) => r.body && r.body.length > 0,
      'X-Cache is defined (json)': (r) => r.headers['X-Cache'] !== undefined,
    });

    // Se as verificações falharem consistentemente, considera abortar
    if (!jsonChecks) {
      console.warn(`⚠️ Verificações falharam para JSON ID: ${id}`);
    }

  } catch (error) {
    console.error(`❌ Erro na requisição JSON ID: ${id} - ${error}`);
    if (isCriticalError(error)) {
      abort('Teste abortado devido a erro crítico de conexão');
    }
  }

  // Pequena pausa entre requisições
  sleep(1);

  // Image request
  let resImg;
  try {
    resImg = http.get(`${baseURL}/api/character/avatar/${id}.jpeg`, {
      headers: Object.assign({}, hostHeader, {
        Accept: 'image/jpeg',
      }),
      timeout: '30s', // Adiciona timeout
    });

    console.info(
      `🟡 IMG ID: ${id} - Status: ${resImg.status} - X-Cache: ${resImg.headers['X-Cache']}`
    );

    // Verifica se houve erro crítico na resposta
    if (resImg.error && isCriticalError(resImg.error)) {
      console.error(`❌ Erro crítico detectado: ${resImg.error}`);
      abort('Teste abortado devido a erro crítico de conexão');
    }

    const imgChecks = check(resImg, {
      'status is 200 (img)': (r) => r.status === 200,
      'image is not empty': (r) => r.body && r.body.length > 0,
      'X-Cache is defined (img)': (r) => r.headers['X-Cache'] !== undefined,
    });

    // Se as verificações falharem consistentemente, considera abortar
    if (!imgChecks) {
      console.warn(`⚠️ Verificações falharam para IMG ID: ${id}`);
    }

  } catch (error) {
    console.error(`❌ Erro na requisição IMG ID: ${id} - ${error}`);
    if (isCriticalError(error)) {
      abort('Teste abortado devido a erro crítico de conexão');
    }
  }

  // Pequena pausa entre iterações
  sleep(1);
}

// Função de setup opcional para verificar conectividade inicial
export function setup() {
  console.log('🔍 Verificando conectividade com o servidor...');
  const testResponse = http.get('http://nginx:8889/health', { timeout: '10s' });
  
  if (testResponse.status !== 200) {
    console.error('❌ Servidor não está respondendo. Abortando teste.');
    abort('Servidor não disponível');
  }
  
  console.log('✅ Servidor está respondendo. Iniciando teste...');
}
