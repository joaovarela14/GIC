FROM node:20-alpine

WORKDIR /app

COPY package.json package-lock.json ./

RUN npm ci --legacy-peer-deps

COPY . .

EXPOSE 8000

CMD ["npm", "run", "dev", "--", "--hostname", "0.0.0.0"]
