# The AI container (agent/server.mjs). Built by wrangler from each Worker's config; linux/amd64.
# /app, the code and its packages, stays root's and read only to the agent user; checkouts and clones go under its home.
FROM node:22-slim
RUN apt-get update && apt-get install -y --no-install-recommends git ca-certificates && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev && useradd -m agent && chmod -R a-w /app
COPY server.mjs read-tools.mjs ./
RUN chmod a-w server.mjs read-tools.mjs /app
USER agent
ENV HOME=/home/agent
EXPOSE 8080
CMD ["node", "server.mjs"]
