import { spawn, spawnSync, type ChildProcess } from 'node:child_process'
import { randomBytes } from 'node:crypto'
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import {
  createServer,
  request,
  type IncomingMessage,
  type OutgoingHttpHeaders,
  type ServerResponse,
} from 'node:http'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const PORT = Number.parseInt(
  process.env.OPENCLAW_PUBLIC_PORT ??
    process.env.CLAWDBOT_PUBLIC_PORT ??
    process.env.PORT ??
    '8080',
  10
)

const STATE_DIR =
  process.env.OPENCLAW_STATE_DIR?.trim() ||
  process.env.CLAWDBOT_STATE_DIR?.trim() ||
  path.join(os.homedir(), '.openclaw')

const WORKSPACE_DIR =
  process.env.OPENCLAW_WORKSPACE_DIR?.trim() ||
  process.env.CLAWDBOT_WORKSPACE_DIR?.trim() ||
  path.join(STATE_DIR, 'workspace')

function resolveGatewayToken(): string {
  const envTok =
    process.env.OPENCLAW_GATEWAY_TOKEN?.trim() || process.env.CLAWDBOT_GATEWAY_TOKEN?.trim()
  if (envTok) return envTok

  const tokenPath = path.join(STATE_DIR, 'gateway.token')
  try {
    const existing = readFileSync(tokenPath, 'utf8').trim()
    if (existing) return existing
  } catch {
    // ignore
  }

  const generated = randomBytes(32).toString('hex')
  try {
    mkdirSync(STATE_DIR, { recursive: true })
    writeFileSync(tokenPath, generated, { encoding: 'utf8', mode: 0o600 })
  } catch {
    // best-effort
  }
  return generated
}

const OPENCLAW_GATEWAY_TOKEN = resolveGatewayToken()
process.env.OPENCLAW_GATEWAY_TOKEN = OPENCLAW_GATEWAY_TOKEN
process.env.CLAWDBOT_GATEWAY_TOKEN = process.env.CLAWDBOT_GATEWAY_TOKEN || OPENCLAW_GATEWAY_TOKEN

const INTERNAL_GATEWAY_PORT = Number.parseInt(process.env.INTERNAL_GATEWAY_PORT ?? '18789', 10)
const INTERNAL_GATEWAY_HOST = process.env.INTERNAL_GATEWAY_HOST ?? '127.0.0.1'
const GATEWAY_TARGET = `http://${INTERNAL_GATEWAY_HOST}:${INTERNAL_GATEWAY_PORT}`

const OPENCLAW_ENTRY = process.env.OPENCLAW_ENTRY?.trim()
const OPENCLAW_NODE = process.env.OPENCLAW_NODE?.trim() || 'node'

const DIST_DIR = path.dirname(fileURLToPath(import.meta.url))
const LOCAL_BIN_OPENCLAW = path.resolve(DIST_DIR, '../node_modules/.bin/openclaw')

function configureGitIdentityFromEnv(): void {
  // Mirror `docker-entrypoint.sh` behavior but keep it best-effort.
  // Expected vars:
  // - GITHUB_USER_NAME
  // - GITHUB_USER_EMAIL
  const name = process.env.GITHUB_USER_NAME?.trim()
  const email = process.env.GITHUB_USER_EMAIL?.trim()
  if (!name && !email) return

  try {
    const check = spawnSync('git', ['--version'], { stdio: 'ignore' })
    if (check.error || check.status !== 0) return
  } catch {
    return
  }

  try {
    if (name) spawnSync('git', ['config', '--global', 'user.name', name], { stdio: 'ignore' })
    if (email) spawnSync('git', ['config', '--global', 'user.email', email], { stdio: 'ignore' })
  } catch {
    // ignore
  }
}

function resolveOpenclawCommand(): { cmd: string; argsPrefix: string[] } {
  // Explicit override (preferred)
  const envCmd = process.env.OPENCLAW_CMD?.trim()
  if (envCmd) return { cmd: envCmd, argsPrefix: [] }

  // If an explicit entry path is given, preserve legacy behavior: `node entry.js ...`
  if (OPENCLAW_ENTRY) return { cmd: OPENCLAW_NODE, argsPrefix: [OPENCLAW_ENTRY] }

  // Docker image provides /usr/local/bin/openclaw
  if (existsSync('/usr/local/bin/openclaw'))
    return { cmd: '/usr/local/bin/openclaw', argsPrefix: [] }

  // Local dev: resolve within this package (works even if CWD is repo root)
  if (existsSync(LOCAL_BIN_OPENCLAW)) return { cmd: LOCAL_BIN_OPENCLAW, argsPrefix: [] }

  // Last resort: rely on PATH
  return { cmd: 'openclaw', argsPrefix: [] }
}

function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms))
}

let gatewayProc: ChildProcess | null = null

function startGateway(): void {
  if (gatewayProc) return

  configureGitIdentityFromEnv()

  mkdirSync(STATE_DIR, { recursive: true })
  mkdirSync(WORKSPACE_DIR, { recursive: true })

  const { cmd, argsPrefix } = resolveOpenclawCommand()
  const args = [
    ...argsPrefix,
    'gateway',
    'run',
    '--bind',
    'loopback',
    '--port',
    String(INTERNAL_GATEWAY_PORT),
    '--auth',
    'token',
    '--token',
    OPENCLAW_GATEWAY_TOKEN,
  ]

  gatewayProc = spawn(cmd, args, {
    stdio: 'inherit',
    env: {
      ...process.env,
      OPENCLAW_STATE_DIR: STATE_DIR,
      OPENCLAW_WORKSPACE_DIR: WORKSPACE_DIR,
      // Backward-compat aliases
      CLAWDBOT_STATE_DIR: process.env.CLAWDBOT_STATE_DIR || STATE_DIR,
      CLAWDBOT_WORKSPACE_DIR: process.env.CLAWDBOT_WORKSPACE_DIR || WORKSPACE_DIR,
    },
  })

  gatewayProc.on('exit', (code, signal) => {
    console.error(`[gateway] exited code=${code} signal=${signal}`)
    gatewayProc = null
  })
  gatewayProc.on('error', (err) => {
    console.error(`[gateway] spawn error: ${String(err)}`)
    gatewayProc = null
  })
}

async function waitForGatewayReady({
  timeoutMs = 20_000,
}: {
  timeoutMs?: number
} = {}): Promise<boolean> {
  const start = Date.now()
  while (Date.now() - start < timeoutMs) {
    try {
      const paths = ['/openclaw', '/clawdbot', '/']
      for (const p of paths) {
        try {
          // Any HTTP response means the port is open.
          const res = await fetch(`${GATEWAY_TARGET}${p}`, { method: 'GET' })
          if (res) return true
        } catch {
          // try next
        }
      }
    } catch {
      // ignore
    }
    await sleep(250)
  }
  return false
}

function proxyToGateway(req: IncomingMessage, res: ServerResponse): void {
  const url = new URL(req.url ?? '/', GATEWAY_TARGET)
  const headers = { ...req.headers, host: url.host } as OutgoingHttpHeaders

  const upstreamReq = request(
    {
      protocol: url.protocol,
      hostname: url.hostname,
      port: url.port,
      method: req.method,
      path: `${url.pathname}${url.search}`,
      headers,
    },
    (upstreamRes) => {
      res.writeHead(upstreamRes.statusCode ?? 502, upstreamRes.headers)
      upstreamRes.pipe(res)
    }
  )

  upstreamReq.on('error', (err) => {
    res.statusCode = 502
    res.setHeader('content-type', 'application/json; charset=utf-8')
    res.end(JSON.stringify({ ok: false, error: String(err) }))
  })

  req.pipe(upstreamReq)
}

function shutdown(): void {
  try {
    gatewayProc?.kill('SIGTERM')
  } catch {
    // ignore
  }
}

process.on('SIGTERM', () => {
  shutdown()
  process.exit(0)
})
process.on('SIGINT', () => {
  shutdown()
  process.exit(0)
})

let gatewayReady = false
startGateway()
waitForGatewayReady({ timeoutMs: 20_000 })
  .then((ready) => {
    gatewayReady = Boolean(ready)
    console.log(`[wrapper] gateway ready: ${gatewayReady}`)
  })
  .catch((err) => {
    console.error(`[wrapper] gateway readiness check failed: ${String(err)}`)
  })

const server = createServer((req, res) => {
  if ((req.url ?? '/') === '/healthz') {
    res.statusCode = 200
    res.setHeader('content-type', 'application/json; charset=utf-8')
    res.end(
      JSON.stringify({
        ok: true,
        gateway: { target: GATEWAY_TARGET, running: Boolean(gatewayProc), ready: gatewayReady },
      })
    )
    return
  }
  proxyToGateway(req, res)
})

server.listen(PORT, '0.0.0.0', () => {
  console.log(`[wrapper] listening on :${PORT}`)
  console.log(`[wrapper] gateway target: ${GATEWAY_TARGET}`)
})
