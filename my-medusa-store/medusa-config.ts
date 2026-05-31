import { loadEnv, defineConfig } from '@medusajs/framework/utils'
import type { RedisOptions } from "ioredis"

loadEnv(process.env.NODE_ENV || 'development', process.cwd())

const sharedRedisUrl = process.env.REDIS_URL
const cookieSecure =
  process.env.COOKIE_SECURE !== undefined
    ? process.env.COOKIE_SECURE === "true"
    : process.env.NODE_ENV === "production"
const cookieSameSite = (process.env.COOKIE_SAME_SITE ||
  (cookieSecure ? "none" : "lax")) as "strict" | "lax" | "none"

const DEFAULT_SENTINEL_PORT = 26379

function parseSentinelEndpoint(endpoint: string) {
  const [host, portValue] = endpoint.trim().split(":")

  if (!host) {
    throw new Error("Redis Sentinel host cannot be empty")
  }

  const port = portValue ? Number(portValue) : DEFAULT_SENTINEL_PORT

  if (!Number.isInteger(port) || port <= 0 || port > 65535) {
    throw new Error(`Invalid Redis Sentinel port for ${host}: ${portValue}`)
  }

  return {
    host,
    port,
  }
}

function parseSentinelHosts(hosts?: string) {
  if (!hosts) {
    return []
  }

  return hosts
    .split(",")
    .map((endpoint) => endpoint.trim())
    .filter(Boolean)
    .map(parseSentinelEndpoint)
}

function buildRedisConnectionOptions(): RedisOptions {
  const sentinels = parseSentinelHosts(process.env.REDIS_SENTINEL_HOSTS)
  const sentinelName = process.env.REDIS_SENTINEL_NAME

  if (!sentinels.length && !sentinelName) {
    return {}
  }

  if (!sentinels.length || !sentinelName) {
    throw new Error(
      "Both REDIS_SENTINEL_HOSTS and REDIS_SENTINEL_NAME must be set for Redis Sentinel"
    )
  }

  return {
    sentinels,
    name: sentinelName,
    role: "master",
    sentinelRetryStrategy: (attempts) => Math.min(attempts * 100, 2000),
    reconnectOnError: (error) => {
      if (error.message.includes("READONLY")) {
        return 2
      }

      return false
    },
  }
}

const redisConnectionOptions = buildRedisConnectionOptions()
const fileModule = process.env.S3_BUCKET
  ? [
      {
        resolve: "@medusajs/file",
        options: {
          providers: [
            {
              resolve: "@medusajs/file-s3",
              id: "s3",
              options: {
                file_url: process.env.S3_FILE_URL,
                endpoint: process.env.S3_ENDPOINT,
                bucket: process.env.S3_BUCKET,
                region: process.env.S3_REGION,
                access_key_id: process.env.S3_ACCESS_KEY_ID,
                secret_access_key: process.env.S3_SECRET_ACCESS_KEY,
                additional_client_config: {
                  forcePathStyle: true,
                },
              },
            },
          ],
        },
      },
    ]
  : []

module.exports = defineConfig({
  projectConfig: {
    databaseUrl: process.env.DATABASE_URL,
    redisUrl: sharedRedisUrl,
    redisOptions: redisConnectionOptions,
    workerMode:
      (process.env.MEDUSA_WORKER_MODE as "shared" | "server" | "worker") ||
      "shared",
    http: {
      storeCors: process.env.STORE_CORS!,
      adminCors: process.env.ADMIN_CORS!,
      authCors: process.env.AUTH_CORS!,
      jwtSecret: process.env.JWT_SECRET || "supersecret",
      cookieSecret: process.env.COOKIE_SECRET || "supersecret",
    },
    cookieOptions: {
      secure: cookieSecure,
      sameSite: cookieSameSite,
    },
    databaseDriverOptions: {
      ssl: false,
      sslmode: "disable",
    },
  },
  modules: [
    ...fileModule,
    {
      resolve: "@medusajs/medusa/caching",
      options: {
        providers: [
          {
            resolve: "@medusajs/caching-redis",
            id: "caching-redis",
            is_default: true,
            options: {
              redisUrl: process.env.CACHE_REDIS_URL || sharedRedisUrl,
              ...redisConnectionOptions,
            },
          },
        ],
      },
    },
    {
      resolve: "@medusajs/medusa/event-bus-redis",
      options: {
        redisUrl: process.env.EVENTS_REDIS_URL || sharedRedisUrl,
        redisOptions: redisConnectionOptions,
      },
    },
    {
      resolve: "@medusajs/medusa/workflow-engine-redis",
      options: {
        redis: {
          redisUrl: process.env.WE_REDIS_URL || sharedRedisUrl,
          redisOptions: redisConnectionOptions,
        },
      },
    },
    {
      resolve: "@medusajs/medusa/locking",
      options: {
        providers: [
          {
            resolve: "@medusajs/medusa/locking-redis",
            id: "locking-redis",
            is_default: true,
            options: {
              redisUrl: process.env.LOCKING_REDIS_URL || sharedRedisUrl,
              redisOptions: redisConnectionOptions,
            },
          },
        ],
      },
    },
  ],
  admin: {
    disable: process.env.DISABLE_MEDUSA_ADMIN === "true",
    ...(process.env.NODE_ENV === "development"
      ? {
          vite: () => {
            return {
              server: {
                host: "0.0.0.0",
                allowedHosts: [
                  "localhost",
                  ".localhost",
                  "127.0.0.1",
                ],
                hmr: {
                  port: 5173,
                  clientPort: 5173,
                },
              },
            }
          },
        }
      : {}),
  },
})
