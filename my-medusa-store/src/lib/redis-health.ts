import Redis from "ioredis"
import type { RedisOptions } from "ioredis"

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

function buildRedisConnectionOptions(): RedisOptions {
  const sentinels = (process.env.REDIS_SENTINEL_HOSTS || "")
    .split(",")
    .map((endpoint) => endpoint.trim())
    .filter(Boolean)
    .map(parseSentinelEndpoint)
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

export async function pingRedis(redisUrl: string, timeoutMs: number) {
  const redis = new Redis(redisUrl, {
    ...buildRedisConnectionOptions(),
    lazyConnect: true,
    connectTimeout: timeoutMs,
    commandTimeout: timeoutMs,
    enableOfflineQueue: false,
    maxRetriesPerRequest: 1,
  })

  try {
    await redis.connect()
    await redis.ping()
  } finally {
    redis.disconnect()
  }
}
