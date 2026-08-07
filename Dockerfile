ARG NODE_IMAGE_VERSION="22-alpine"

# Install dependencies only when needed
FROM node:${NODE_IMAGE_VERSION} AS deps
# Check https://github.com/nodejs/docker-node/tree/b4117f9333da4138b03a546ec926ef50a31506c3#nodealpine to understand why libc6-compat might be needed.
RUN apk add --no-cache libc6-compat
WORKDIR /app
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
RUN npm install -g pnpm
RUN pnpm install --frozen-lockfile

# Rebuild the source code only when needed
FROM node:${NODE_IMAGE_VERSION} AS builder
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY . .
COPY docker/proxy.ts ./src

ARG BASE_PATH

ENV BASE_PATH=$BASE_PATH
ENV NEXT_TELEMETRY_DISABLED=1
ENV DATABASE_URL="postgresql://user:pass@localhost:5432/dummy"

RUN npm run build-docker

# Production image, copy all the files and run next
FROM node:${NODE_IMAGE_VERSION} AS runner
WORKDIR /app

ARG PRISMA_VERSION="7.3.0"
ARG NODE_OPTIONS

ENV NODE_ENV=production
ENV NEXT_TELEMETRY_DISABLED=1
ENV NODE_OPTIONS=$NODE_OPTIONS

RUN addgroup --system --gid 1001 nodejs
RUN adduser --system --uid 1001 nextjs
RUN set -x \
    && apk add --no-cache curl \
    && npm install -g pnpm

COPY --from=builder --chown=nextjs:nodejs /app/public ./public
COPY --from=builder /app/prisma ./prisma
COPY --from=builder /app/prisma.config.ts ./prisma.config.ts
COPY --from=builder /app/scripts ./scripts
COPY --from=builder /app/generated ./generated

# Automatically leverage output traces to reduce image size
# https://nextjs.org/docs/advanced-features/output-file-tracing
COPY --from=builder --chown=nextjs:nodejs /app/.next/standalone ./
COPY --from=builder --chown=nextjs:nodejs /app/.next/static ./.next/static

# Script dependencies (check-db.js / update-tracker.js need these at runtime).
# MUST run after the .next/standalone COPY above: Next.js's standalone output ships its
# own pruned node_modules subset (only what Next.js itself imports), and copying it over
# /app/node_modules clobbers earlier packages with incomplete versions -- e.g. its own
# traced "semver" copy is missing index.js because Next.js's internal code never touches
# it, which then breaks check-db.js's separate `import semver from 'semver'`. Installing
# these packages LAST, after standalone is in place, is what makes them the ones that stick.
# Next.js's own package.json (now sitting in /app from the standalone COPY) pulls in its
# transitive build tooling (@swc/core, @parcel/watcher, ...), so this `pnpm add` needs the
# same allowBuilds decisions as the deps stage -- copy pnpm-workspace.yaml here too.
COPY pnpm-workspace.yaml ./
RUN pnpm --allow-build='@prisma/engines' --allow-build='prisma' add npm-run-all dotenv chalk semver \
    prisma@${PRISMA_VERSION} \
    @prisma/client@${PRISMA_VERSION} \
    @prisma/adapter-pg@${PRISMA_VERSION}

USER nextjs

EXPOSE 3000

ENV HOSTNAME=0.0.0.0
ENV PORT=3000

# Use npm (not pnpm) to run the startup script: pnpm 10+'s automatic "deps status check"
# considers this directory's node_modules (assembled from multiple COPY sources above,
# not a single `pnpm install`) permanently "out of sync" with pnpm-lock.yaml, and tries to
# silently self-heal via `pnpm install` -- which fails with EACCES since we're running as
# the unprivileged nextjs user against root-owned build output. npm has no such check.
CMD ["npm", "run", "start-docker"]