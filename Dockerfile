FROM ruby:3.3.6-slim-bookworm AS base

ENV BUNDLE_WITHOUT=development:test \
    BUNDLE_DEPLOYMENT=1 \
    BUNDLE_PATH=/usr/local/bundle \
    LANG=C.UTF-8 \
    MUNI_LOG_LEVEL=info \
    MUNI_DB_PATH=/data/muni.sqlite3

RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends \
      build-essential libsqlite3-dev curl ca-certificates tini && \
    rm -rf /var/lib/apt/lists/*

# Caddy runs beside Puma and the collector on the single data-owning Machine.
RUN curl -fsSL -o /usr/local/bin/caddy \
      "https://caddyserver.com/api/download?os=linux&arch=$(dpkg --print-architecture)" \
    && chmod +x /usr/local/bin/caddy

WORKDIR /app
COPY Gemfile Gemfile.lock ./
COPY core/muni-core.gemspec core/
COPY cli/muni-cli.gemspec   cli/
COPY www/www.gemspec        www/
COPY core/lib/muni/version.rb core/lib/muni/
RUN bundle install --jobs 4 --retry 3

COPY . .

# Migrations run on the mounted volume in bin/start before the supervisor.
# Verify the bundle and proxy configuration while building the image.
RUN mkdir -p /data /app/tmp \
    && bundle exec ruby -e "require 'muni'; puts Muni::VERSION" \
    && caddy validate --config /app/Caddyfile --adapter caddyfile

EXPOSE 8080 4567
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["bin/start", "web"]
