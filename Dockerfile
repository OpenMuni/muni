FROM golang:1.27.2-bookworm AS proxy
WORKDIR /src
COPY build/caddy/go.mod build/caddy/go.sum ./
RUN go mod download
COPY build/caddy/main.go ./
RUN CGO_ENABLED=0 go build -trimpath -o /caddy .

FROM ruby:3.3.12-slim-trixie AS base

ENV BUNDLE_WITHOUT=development:test \
    BUNDLE_DEPLOYMENT=1 \
    BUNDLE_PATH=/usr/local/bundle \
    LANG=C.UTF-8 \
    MUNI_LOG_LEVEL=info \
    MUNI_DB_PATH=/data/muni.sqlite3

RUN apt-get update -qq && \
    apt-get upgrade -y && \
    apt-get install -y --no-install-recommends \
      curl ca-certificates tini && \
    rm -rf /var/lib/apt/lists/*

# Caddy runs beside Puma and the collector on the single data-owning host.
COPY --from=proxy /caddy /usr/local/bin/caddy

# Replace the vulnerable bundled resolver as well as locking the app's version.
# Remove its old implementation, not just its scanner-visible gemspec.
RUN gem install resolv --version 0.3.2 --no-document --install-dir /usr/local/lib/ruby/gems/3.3.0 && \
    rm -f /usr/local/lib/ruby/gems/3.3.0/specifications/default/resolv-0.3.1.gemspec \
          /usr/local/lib/ruby/3.3.0/resolv.rb && \
    rm -rf /usr/local/lib/ruby/3.3.0/resolv \
           /usr/local/lib/ruby/gems/3.3.0/gems/resolv-0.3.1 && \
    ruby -rresolv -e 'abort "resolver upgrade failed" unless Gem.loaded_specs.fetch("resolv").version.to_s == "0.3.2"'

WORKDIR /app
COPY Gemfile Gemfile.lock ./
COPY core/muni-core.gemspec core/
COPY cli/muni-cli.gemspec   cli/
COPY www/www.gemspec        www/
COPY core/lib/muni/version.rb core/lib/muni/
RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends build-essential zlib1g-dev && \
    bundle install --jobs 4 --retry 3 && \
    apt-get purge -y --auto-remove build-essential zlib1g-dev && \
    rm -rf /var/lib/apt/lists/*

COPY . .

# Migrations run on the mounted volume in bin/start before the supervisor.
# Verify the bundle and proxy configuration while building the image.
RUN mkdir -p /data /app/tmp \
    && bundle exec ruby -e "require 'muni'; puts Muni::VERSION" \
    && caddy validate --config /app/Caddyfile --adapter caddyfile

EXPOSE 8080 4567
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["bin/start", "web"]
