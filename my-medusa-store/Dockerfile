# Development Dockerfile for Medusa
FROM node:20-alpine

# Set working directory
WORKDIR /server

# Copy package files and npm config
COPY package.json package-lock.json ./

# Install all dependencies using npm
RUN npm ci --legacy-peer-deps

# Copy source code
COPY . .

# Build the Medusa production bundle and admin dashboard
RUN npm run build

# Fail the image build early if Medusa didn't produce the production server bundle.
RUN test -f /server/.medusa/server/package.json \
 && test -f /server/.medusa/server/public/admin/index.html

# Expose the port Medusa runs on
EXPOSE 9000 5173

# Start with migrations and then the production server
ENTRYPOINT ["./start.sh"]
