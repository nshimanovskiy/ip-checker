FROM node:20-alpine
WORKDIR /app
COPY server.js ./
COPY public ./public
ENV NODE_ENV=production PORT=3077
USER node
EXPOSE 3077
HEALTHCHECK --interval=30s --timeout=3s CMD wget -qO- http://127.0.0.1:3077/healthz || exit 1
CMD ["node", "server.js"]
