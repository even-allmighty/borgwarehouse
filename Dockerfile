FROM node:22-bookworm-slim as base

# build stage
FROM base AS deps

WORKDIR /app

COPY package.json package-lock.json ./

RUN npm ci --omit=dev

FROM base AS builder

WORKDIR /app

COPY --from=deps /app/node_modules ./node_modules

COPY --exclude=docker --exclude=helpers/shells . .

RUN sed -i "s/images:/output: 'standalone',images:/" next.config.ts

RUN npm run build

# run stage
FROM base AS runner


ENV NODE_ENV production
ENV HOSTNAME=

ENV DATA_DIR="/data"
ENV SSH_MOUNT_DIR="$DATA_DIR/ssh"
ENV SSH_CLIENT_DIR="$SSH_MOUNT_DIR/auth"
ENV SSH_HOST_KEYS_DIR="$SSH_MOUNT_DIR/host_keys"
ENV AUTHORIZED_KEYS_FILE="$SSH_MOUNT_DIR/authorized_keys"

RUN echo 'deb http://deb.debian.org/debian bookworm-backports main' >> /etc/apt/sources.list
RUN apt-get update && apt-get install -y \
    supervisor curl jq jc borgbackup/bookworm-backports openssh-server libnss-wrapper && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /app

WORKDIR /app

COPY --from=builder --chown=borgwarehouse:borgwarehouse /app/LICENSE ./
COPY --from=builder --chown=borgwarehouse:borgwarehouse /app/.next/standalone ./
COPY --from=builder --chown=borgwarehouse:borgwarehouse /app/public ./public
COPY --from=builder --chown=borgwarehouse:borgwarehouse /app/.next/static ./.next/static

COPY docker/supervisord.conf docker/docker-bw-init.sh ./
COPY helpers/shells ./helpers/shells
COPY docker/sshd_config /etc/ssh/sshd_config

EXPOSE 3000 22

ENTRYPOINT ["./docker-bw-init.sh"]
