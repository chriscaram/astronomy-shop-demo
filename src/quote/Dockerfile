# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0


FROM ghcr.io/mlocati/php-extension-installer:2.13.1@sha256:35821db0661308f64aa18483bb3af56bedc3b40090ff441ed961327d1ccbceb8 AS installer

FROM docker.io/library/composer:2.10.3@sha256:b6dcd72ca98fa19d0e5b8476de179859704891fad06dd9e0b96833d4c430a5fc AS vendor

WORKDIR /tmp/

COPY ./src/quote/composer.json composer.json

RUN composer install \
    --ignore-platform-reqs \
    --no-interaction \
    --no-plugins \
    --no-scripts \
    --no-dev \
    --prefer-dist

FROM docker.io/library/php:8.5.12-cli-alpine3.24@sha256:e899a75c775804e5466dbd9c96b31f8b6c6ae2ddb053a8466223a0c32992ff8e

COPY --from=installer /usr/bin/install-php-extensions /usr/local/bin/

RUN install-php-extensions opcache pcntl protobuf opentelemetry

WORKDIR /var/www

USER www-data

COPY --from=vendor /tmp/vendor/ vendor/

COPY ./src/quote/app/ app/
COPY ./src/quote/public/ public/
COPY ./src/quote/src/ src/

ARG QUOTE_PORT=8090
EXPOSE ${QUOTE_PORT}

CMD ["php", "public/index.php"]
