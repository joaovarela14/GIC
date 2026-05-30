import { loadEnv, defineConfig } from '@medusajs/framework/utils'
import { buildRedisConnectionOptions } from "./src/lib/redis-options"

loadEnv(process.env.NODE_ENV || 'development', process.cwd())

const sharedRedisUrl = process.env.REDIS_URL
const redisConnectionOptions = buildRedisConnectionOptions()
const cookieSecure =
  process.env.COOKIE_SECURE !== undefined
    ? process.env.COOKIE_SECURE === "true"
    : process.env.NODE_ENV === "production"
const cookieSameSite = (process.env.COOKIE_SAME_SITE ||
  (cookieSecure ? "none" : "lax")) as "strict" | "lax" | "none"

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
