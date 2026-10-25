# php/Dockerfile — PHP 8.2-FPM + PostgreSQL (pdo_pgsql) + Ghostscript

# PHP 8.2 con Debian Bookworm (estable)
FROM php:8.2-fpm-bookworm

# Dependencias del sistema (incluye Ghostscript para compresión PDF de Laravel)
RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl wget unzip zip \
    libpng-dev libjpeg-dev libfreetype6-dev libwebp-dev \
    libxml2-dev libzip-dev libcurl4-openssl-dev \
    libonig-dev libsqlite3-dev libpq-dev \
    libssl-dev libpcre2-dev \
    fonts-freefont-ttf \
    ghostscript \
    && rm -rf /var/lib/apt/lists/*

# Extensiones PHP
RUN docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp \
    && docker-php-ext-install -j$(nproc) \
        pdo pdo_mysql pdo_pgsql pdo_sqlite \
        mbstring xml bcmath gd curl zip intl \
        opcache pcntl

# Redis
RUN pecl install redis && docker-php-ext-enable redis

# Composer
COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

# Configuración PHP
COPY php.ini /usr/local/etc/php/conf.d/custom.ini
# Pool PHP-FPM parametrizado (reemplaza el default de 5 workers de la imagen)
COPY www.conf /usr/local/etc/php-fpm.d/www.conf

WORKDIR /var/www/html

CMD ["php-fpm"]

EXPOSE 9000