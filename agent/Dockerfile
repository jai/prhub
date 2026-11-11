# The AI container (agent/server.mjs). Built by wrangler from each Worker's config; linux/amd64.
FROM node:22-slim
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev && useradd -m agent && chown -R agent /app
COPY server.mjs ./
USER agent
ENV HOME=/home/agent
EXPOSE 8080
CMD ["node", "server.mjs"]
