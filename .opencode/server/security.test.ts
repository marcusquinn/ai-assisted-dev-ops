import { afterEach, describe, expect, test } from 'bun:test'
import { networkInterfaces } from 'node:os'
import {
  DEFAULT_LISTEN_HOST,
  getListenHost,
  hasValidBearerToken,
  parseAllowedOrigins,
  requireServerToken,
} from './security'

const REPOSITORY_ROOT = new URL('../../', import.meta.url).pathname
const TEST_TOKEN = 'test-only-local-server-token-0123456789'
const childProcesses: Array<ReturnType<typeof spawnServer>> = []

function createChildEnvironment(overrides: Record<string, string | undefined>): Record<string, string> {
  const environment: Record<string, string> = {}
  for (const [name, value] of Object.entries(process.env)) {
    if (value !== undefined) environment[name] = value
  }
  for (const [name, value] of Object.entries(overrides)) {
    if (value === undefined) delete environment[name]
    else environment[name] = value
  }
  return environment
}

function spawnServer(script: string, environment: Record<string, string | undefined>) {
  return Bun.spawn([process.execPath, 'run', script], {
    cwd: REPOSITORY_ROOT,
    env: createChildEnvironment(environment),
    stdout: 'ignore',
    stderr: 'pipe',
  })
}

async function allocateLoopbackPort(): Promise<number> {
  const reservation = Bun.serve({
    hostname: DEFAULT_LISTEN_HOST,
    port: 0,
    fetch: () => new Response('reserved'),
	})
	const port = reservation.port
	await reservation.stop(true)
	if (port === undefined) {
		throw new Error('Loopback port reservation did not return a port.')
	}
	return port
}

async function waitForServer(url: string, headers: HeadersInit = {}): Promise<void> {
  for (let attempt = 0; attempt < 60; attempt++) {
    try {
      await fetch(url, { headers, signal: AbortSignal.timeout(250) })
      return
    } catch {
      await Bun.sleep(50)
    }
  }
  throw new Error(`Timed out waiting for ${url}`)
}

function getNonLoopbackIpv4Address(): string | undefined {
  for (const addresses of Object.values(networkInterfaces())) {
    for (const address of addresses ?? []) {
      if (!address.internal && address.family === 'IPv4') return address.address
    }
  }
  return undefined
}

async function expectLoopbackOnly(port: number, path: string, headers: HeadersInit = {}): Promise<void> {
  const address = getNonLoopbackIpv4Address()
  if (!address) return

  let reachable = false
  try {
    await fetch(`http://${address}:${port}${path}`, {
      headers,
      signal: AbortSignal.timeout(500),
    })
    reachable = true
  } catch {
    reachable = false
  }
  expect(reachable).toBe(false)
}

async function expectStartupFailure(
  script: string,
  environment: Record<string, string | undefined>,
  expectedMessage: string,
): Promise<void> {
  const process = spawnServer(script, environment)
  const exitCode = await Promise.race([
    process.exited,
    Bun.sleep(3000).then(() => null),
  ])
  if (exitCode === null) {
    process.kill()
    throw new Error(`${script} did not fail closed when its token was missing`)
  }
  const errorOutput = await new Response(process.stderr).text()
  expect(exitCode).not.toBe(0)
  expect(errorOutput).toContain(expectedMessage)
}

afterEach(async () => {
  const processes = childProcesses.splice(0)
  for (const process of processes) {
    if (process.exitCode === null) process.kill()
  }
  await Promise.allSettled(processes.map(process => process.exited))
})

describe('local server security helpers', () => {
  test('defaults to the IPv4 loopback interface', () => {
    expect(getListenHost(undefined)).toBe(DEFAULT_LISTEN_HOST)
    expect(getListenHost('')).toBe(DEFAULT_LISTEN_HOST)
    expect(getListenHost(' 127.0.0.1 ')).toBe(DEFAULT_LISTEN_HOST)
    expect(getListenHost('0.0.0.0')).toBe('0.0.0.0')
  })

  test('requires a non-empty token', () => {
    expect(() => requireServerToken('SERVER_TOKEN', undefined)).toThrow('SERVER_TOKEN')
    expect(() => requireServerToken('SERVER_TOKEN', '   ')).toThrow('SERVER_TOKEN')
    expect(() => requireServerToken('SERVER_TOKEN', 'too-short')).toThrow('at least 32')
    expect(() => requireServerToken('SERVER_TOKEN', `${TEST_TOKEN}!`)).toThrow('URL-safe')
    expect(requireServerToken('SERVER_TOKEN', ` ${TEST_TOKEN} `)).toBe(TEST_TOKEN)
  })

  test('accepts only an exact bearer token', () => {
    expect(hasValidBearerToken(`Bearer ${TEST_TOKEN}`, TEST_TOKEN)).toBe(true)
    expect(hasValidBearerToken(`bearer ${TEST_TOKEN}`, TEST_TOKEN)).toBe(true)
    expect(hasValidBearerToken(TEST_TOKEN, TEST_TOKEN)).toBe(false)
    expect(hasValidBearerToken(`Bearer wrong-${TEST_TOKEN}`, TEST_TOKEN)).toBe(false)
    expect(hasValidBearerToken(`prefix Bearer ${TEST_TOKEN}`, TEST_TOKEN)).toBe(false)
    expect(hasValidBearerToken(null, TEST_TOKEN)).toBe(false)
  })

  test('allows only explicit HTTP origins', () => {
    expect(parseAllowedOrigins(undefined)).toEqual([])
    expect(parseAllowedOrigins('https://example.com, http://localhost:5173,https://example.com')).toEqual([
      'https://example.com',
      'http://localhost:5173',
    ])
    expect(() => parseAllowedOrigins('*')).toThrow('wildcard')
    expect(() => parseAllowedOrigins('https://example.com/path')).toThrow('without paths')
    expect(() => parseAllowedOrigins('not-an-origin')).toThrow('invalid origin')
  })
})

describe('local server runtime security', () => {
  test('API gateway fails closed without a token', async () => {
    await expectStartupFailure(
      '.opencode/server/api-gateway.ts',
      { API_GATEWAY_TOKEN: '', API_GATEWAY_PORT: String(await allocateLoopbackPort()) },
      'API_GATEWAY_TOKEN',
    )
  })

  test('API gateway authenticates every route and does not reflect untrusted origins', async () => {
    const port = await allocateLoopbackPort()
    const process = spawnServer('.opencode/server/api-gateway.ts', {
      API_GATEWAY_HOST: '',
      API_GATEWAY_PORT: String(port),
      API_GATEWAY_TOKEN: TEST_TOKEN,
      CORS_ORIGINS: 'https://example.com',
    })
    childProcesses.push(process)
    const healthUrl = `http://${DEFAULT_LISTEN_HOST}:${port}/health`
    await waitForServer(healthUrl, { Authorization: `Bearer ${TEST_TOKEN}` })
    await expectLoopbackOnly(port, '/health', { Authorization: `Bearer ${TEST_TOKEN}` })

    expect((await fetch(healthUrl)).status).toBe(401)
    expect((await fetch(healthUrl, { headers: { Authorization: 'Bearer wrong-token' } })).status).toBe(401)

    const allowedOriginResponse = await fetch(healthUrl, {
      headers: { Authorization: `Bearer ${TEST_TOKEN}`, Origin: 'https://example.com' },
    })
    expect(allowedOriginResponse.status).toBe(200)
    expect(allowedOriginResponse.headers.get('access-control-allow-origin')).toBe('https://example.com')
    expect(await allowedOriginResponse.json()).toMatchObject({
      status: 'healthy',
      service: 'api-gateway',
    })

    const untrustedOriginResponse = await fetch(healthUrl, {
      headers: { Authorization: `Bearer ${TEST_TOKEN}`, Origin: 'http://localhost:9999' },
    })
    expect(untrustedOriginResponse.status).toBe(200)
    expect(untrustedOriginResponse.headers.get('access-control-allow-origin')).toBeNull()
  })

  test('MCP dashboard fails closed without a token', async () => {
    await expectStartupFailure(
      '.opencode/server/mcp-dashboard.ts',
      { DASHBOARD_TOKEN: '', MCP_DASHBOARD_PORT: String(await allocateLoopbackPort()) },
      'DASHBOARD_TOKEN',
    )
  })

  test('MCP dashboard requires authentication before server inspection or control', async () => {
    const port = await allocateLoopbackPort()
    const process = spawnServer('.opencode/server/mcp-dashboard.ts', {
      DASHBOARD_TOKEN: TEST_TOKEN,
      MCP_DASHBOARD_HOST: '',
      MCP_DASHBOARD_PORT: String(port),
    })
    childProcesses.push(process)
    const baseUrl = `http://${DEFAULT_LISTEN_HOST}:${port}`
    await waitForServer(`${baseUrl}/health`)
    await expectLoopbackOnly(port, '/health')

    const dashboardHtml = await fetch(baseUrl).then(response => response.text())
    expect(dashboardHtml).toContain("window.location.protocol === 'https:' ? 'wss:' : 'ws:'")
    expect(dashboardHtml).toContain("window.location.host + '/ws'")
    expect(dashboardHtml).not.toContain('ws://localhost:')

    expect((await fetch(`${baseUrl}/api/servers`)).status).toBe(401)
    expect((await fetch(`${baseUrl}/api/servers/memory/start`, { method: 'POST' })).status).toBe(401)
    expect((await fetch(`${baseUrl}/api/servers/memory/stop`, { method: 'POST' })).status).toBe(401)

    const authorizedResponse = await fetch(`${baseUrl}/api/servers/not-configured/start`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${TEST_TOKEN}` },
    })
    expect(authorizedResponse.status).toBe(404)

    const unmanagedStopResponse = await fetch(`${baseUrl}/api/servers/memory/stop`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${TEST_TOKEN}` },
    })
    expect(unmanagedStopResponse.status).toBe(409)

    const authStatus = await fetch(`${baseUrl}/api/auth/status`).then(response => response.json())
    expect(authStatus).toEqual({ required: true, configured: true })

    const health = await fetch(`${baseUrl}/health`).then(response => response.json())
    expect(health).toMatchObject({ status: 'healthy', service: 'mcp-dashboard' })

    const dashboardSource = await Bun.file(`${REPOSITORY_ROOT}.opencode/server/mcp-dashboard.ts`).text()
    expect(dashboardSource).not.toContain("Bun.spawn(['pkill'")
  })

  test('main server binds only to loopback by default', async () => {
    const port = await allocateLoopbackPort()
    const process = spawnServer('.opencode/server/index.ts', {
      OPENCODE_SERVER_HOST: '',
      PORT: String(port),
    })
    childProcesses.push(process)
    await waitForServer(`http://${DEFAULT_LISTEN_HOST}:${port}/health`)
    await expectLoopbackOnly(port, '/health')
  })
})
