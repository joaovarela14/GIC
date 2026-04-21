import { loadEnv, defineConfig } from '@medusajs/framework/utils'

loadEnv(process.env.NODE_ENV || 'development', process.cwd())

module.exports = defineConfig({
  projectConfig: {
    databaseUrl: process.env.DATABASE_URL,
    redisUrl: process.env.REDIS_URL,
    http: {
      storeCors: process.env.STORE_CORS!,
      adminCors: process.env.ADMIN_CORS!,
      authCors: process.env.AUTH_CORS!,
      jwtSecret: process.env.JWT_SECRET || "supersecret",
      cookieSecret: process.env.COOKIE_SECRET || "supersecret",
    },
   databaseDriverOptions: {
      ssl: false,
      sslmode: "disable",
    },
  },
  ...(process.env.NODE_ENV === "development"
    ? {
        admin: {
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
        },
      }
    : {}),
})
