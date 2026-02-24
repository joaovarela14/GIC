# Usa uma imagem estável de Node.js
FROM node:18-alpine

# Instala ferramentas necessárias para dependências nativas
RUN apk add --no-cache python3 make g++

WORKDIR /app/backend

# Instala o CLI do Medusa globalmente
RUN npm install -g @medusajs/medusa-cli

# Copia os ficheiros de configuração (se já os tiveres)
COPY package.json .
RUN npm install

# Copia o resto do código
COPY . .

# Expõe a porta da API e do Admin
EXPOSE 9000
EXPOSE 7001

# Comando para iniciar (Migrations + Seed + Start)
# Isto garante que a BD é criada e populada automaticamente
CMD medusa migrations run && medusa seed -f ./data/seed.json && medusa start