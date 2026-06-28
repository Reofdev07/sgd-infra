# php/Dockerfile — PHP 8.2-FPM + Oracle OCI8 + Ghostscript
# Multi-stage: extrae librerías OCI de gvenzl/oracle-free (sin descargar de Oracle)

# Stage 1: Extraer librerías del cliente Oracle desde gvenzl/oracle-free
# Esto evita descargar de download.oracle.com (que devuelve 403)
FROM gvenzl/oracle-free:latest AS oracle-libs
USER root
RUN mkdir -p /oracle-home/lib /oracle-home/nls /oracle-home/oracore /oracle-home/rdbms/mesg /oracle-home/sdk/include
RUN cp -L /opt/oracle/product/*/dbhomeFree/lib/* /oracle-home/lib/ 2>/dev/null; true
RUN cp -r /opt/oracle/product/*/dbhomeFree/nls/* /oracle-home/nls/ 2>/dev/null; true
RUN cp -r /opt/oracle/product/*/dbhomeFree/oracore/* /oracle-home/oracore/ 2>/dev/null; true
RUN cp -r /opt/oracle/product/*/dbhomeFree/rdbms/mesg/* /oracle-home/rdbms/mesg/ 2>/dev/null; true
RUN mkdir -p /oracle-home/rdbms/public && \
    cp /opt/oracle/product/*/dbhomeFree/rdbms/public/*.h /oracle-home/rdbms/public/ 2>/dev/null; true
RUN ln -s /oracle-home/rdbms/public /oracle-home/sdk/include

# Stage 2: PHP 8.2 con Debian Bookworm (estable)
FROM php:8.2-fpm-bookworm

# Dependencias del sistema (incluye Ghostscript para compresión PDF de Laravel)
RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl wget unzip zip \
    libpng-dev libjpeg-dev libfreetype6-dev \
    libxml2-dev libzip-dev libcurl4-openssl-dev \
    libonig-dev libsqlite3-dev libpq-dev \
    libssl-dev libpcre2-dev \
    libaio1 libaio-dev \
    fonts-freefont-ttf \
    ghostscript \
    && rm -rf /var/lib/apt/lists/*

# Copiar Oracle home (libs + NLS + messages) desde gvenzl/oracle-free
COPY --from=oracle-libs /oracle-home /opt/oracle/product/26ai/dbhomeFree
ENV ORACLE_HOME=/opt/oracle/product/26ai/dbhomeFree
ENV LD_LIBRARY_PATH=/opt/oracle/product/26ai/dbhomeFree/lib
RUN echo /opt/oracle/product/26ai/dbhomeFree/lib > /etc/ld.so.conf.d/oracle-instantclient.conf && \
    ldconfig

# Extensiones PHP
RUN docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install -j$(nproc) \
        pdo pdo_mysql pdo_pgsql pdo_sqlite \
        mbstring xml bcmath gd curl zip intl \
        opcache pcntl

# oci8 (Oracle) — usa el Oracle home completo copiado del stage 1
RUN echo "/opt/oracle/product/26ai/dbhomeFree" | pecl install oci8-3.0.1 \
    && docker-php-ext-enable oci8

# Redis
RUN pecl install redis && docker-php-ext-enable redis

# Composer
COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

# Configuración PHP
COPY php.ini /usr/local/etc/php/conf.d/custom.ini

WORKDIR /var/www/html

CMD ["php-fpm"]

EXPOSE 9000