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
#
# Deliberately NOT installing @prisma/client or @prisma/adapter-pg here (only the `prisma`
# CLI, which check-db.js needs for `execSync('prisma migrate deploy')` and is invoked as a
# binary, not imported -- so Next.js's output tracing never sees it and it's genuinely
# missing without this). @prisma/client + @prisma/adapter-pg ARE imported by the actual app
# code, so Next.js's tracer already bundled a working copy into .next/standalone.
#
# Explicitly pinning pg@8.20.0 (the exact root-lockfile version, also a direct app
# dependency): without it, installing the `prisma` CLI here pulls in its OWN transitive
# `pg` resolution (observed: 8.22.0) into this shared node_modules, silently overwriting
# the correct 8.20.0 the app itself depends on. If you add anything else to this line,
# check whether the root lockfile already pins a version for it and pin it explicitly
# here too, rather than letting pnpm resolve it independently.
COPY pnpm-workspace.yaml ./
RUN pnpm --allow-build='@prisma/engines' --allow-build='prisma' add npm-run-all dotenv chalk semver \
    prisma@${PRISMA_VERSION} \
    pg@8.20.0

# Turbopack's `next build` (in the builder stage) creates synthetic hash-suffixed "external
# module" symlinks under .next/node_modules/<pkg>-<hash> for packages like @prisma/client
# that it treats as externals rather than bundling directly (needed for Prisma's
# dynamically-loaded driver adapters). Each symlink is hardcoded to the EXACT pnpm
# virtual-store path that package happened to live at during THAT build -- but
# .next/standalone's own COPY does not preserve that exact virtual-store layout, and pnpm's
# peer-dependency-aware store can resolve a *different* instance of the same package
# depending on what else gets installed afterward (e.g. the `prisma` CLI pinned above has
# its own peer requirement on @prisma/client, which pnpm satisfies via a distinct virtual-
# store branch). Net effect: these symlinks end up dangling, and any request that touches
# that code path 500s with "Cannot find module '<pkg>-<hash>/...'" -- this broke
# /api/config and /api/auth/verify (blank login page) on 2026-08-07; see CLAUDE.md
# "VORFALL 2026-08-07" for the incident writeup. This reproduces even without any of the
# pnpm-add packages above (root cause is Turbopack's own externals tracing for Prisma
# driver adapters, not something introduced by this Dockerfile) -- so repair it
# unconditionally: any dangling <pkg>-<hash> symlink gets re-pointed at the real,
# correctly-resolved top-level package this image actually ships.
RUN find .next -type l -path '*/node_modules/*' 2>/dev/null | while read -r link; do \
      if [ ! -e "$link" ]; then \
        name=$(basename "$link"); \
        pkg=$(echo "$name" | sed -E 's/-[0-9a-f]{8,}$//'); \
        scope=$(basename "$(dirname "$link")"); \
        case "$scope" in \
          @*) real="/app/node_modules/$scope/$pkg" ;; \
          *)  real="/app/node_modules/$pkg" ;; \
        esac; \
        if [ -e "$real" ]; then \
          rm "$link"; \
          ln -s "$real" "$link"; \
          echo "repaired dangling symlink: $link -> $real"; \
        else \
          echo "WARNING: dangling symlink $link has no repair target at $real -- investigate"; \
        fi; \
      fi; \
    done

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