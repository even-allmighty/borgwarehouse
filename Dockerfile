FROM node:22-bookworm-slim as base

FROM base AS pgkinstall

RUN echo 'deb http://deb.debian.org/debian bookworm-backports main' >> /etc/apt/sources.list
RUN apt-get update && apt-get install -y \
    supervisor curl jq jc borgbackup/bookworm-backports openssh-server libnss-wrapper && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

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
FROM pgkinstall AS runner

RUN mkdir -p /app

WORKDIR /app

COPY --from=builder /app/LICENSE ./
COPY --from=builder /app/.next/standalone ./
COPY --from=builder /app/public ./public
COPY --from=builder /app/.next/static ./.next/static

COPY helpers/shells ./helpers/shells
COPY docker/docker-bw-init.sh docker/supervisord.conf ./
COPY docker/sshd_config /etc/ssh/sshd_config

ENV NODE_ENV production
ENV HOSTNAME=

# Fixed paths for mounted volumes
ENV DATA_DIR="/data"
ENV SSH_CLIENT_MOUNT_DIR="$DATA_DIR/ssh"
ENV SSH_CLIENT_DIR="$SSH_CLIENT_MOUNT_DIR/client"
ENV SSH_HOST_KEYS_DIR="$DATA_DIR/ssh_host_keys"
ENV AUTHORIZED_KEYS_FILE="$SSH_CLIENT_MOUNT_DIR/authorized_keys"
ENV REPOS_MOUNT_DIR="$DATA_DIR/repos"
ENV REPOS_DIR="$REPOS_MOUNT_DIR/repos"

EXPOSE 3000 22

ENTRYPOINT ["./docker-bw-init.sh"]
