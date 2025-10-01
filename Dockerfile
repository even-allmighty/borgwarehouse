FROM node:22-bookworm-slim as base

# build stage
FROM base AS deps

WORKDIR /app

COPY package.json package-lock.json ./

RUN npm ci --omit=dev

FROM base AS builder

WORKDIR /app

COPY --from=deps /app/node_modules ./node_modules

COPY --exclude=docker . .

RUN sed -i "s/images:/output: 'standalone',images:/" next.config.ts

RUN npm run build

# run stage
FROM base AS runner

ENV NODE_ENV production
ENV HOSTNAME=

RUN echo 'deb http://deb.debian.org/debian bookworm-backports main' >> /etc/apt/sources.list
RUN apt-get update && apt-get install -y \
    supervisor curl jq jc borgbackup/bookworm-backports openssh-server && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /app

WORKDIR /app

COPY --from=builder /app/LICENSE ./
COPY --from=builder /app/helpers/shells ./helpers/shells
COPY --from=builder /app/.next/standalone ./
COPY --from=builder /app/public ./public
COPY --from=builder /app/.next/static ./.next/static
COPY --from=builder /app/docker/supervisord.conf ./

EXPOSE 3000 22

ENTRYPOINT ["./docker-bw-init.sh"]
