FROM python:3.9-alpine AS cfgov-dev

# Ensure that the environment uses UTF-8 encoding by default
ENV LANG en_US.UTF-8

LABEL maintainer="tech@cfpb.gov"

# Stops Python default buffering to stdout, improving logging to the console.
ENV PYTHONUNBUFFERED 1

ENV APP_HOME /src/consumerfinance.gov
RUN mkdir -p ${APP_HOME}
WORKDIR ${APP_HOME}

# Install common OS packages
RUN apk add --no-cache --virtual .build-deps gcc musl-dev libffi-dev postgresql-dev zlib-dev jpeg-dev
RUN apk add --no-cache --virtual .backend-deps postgresql
RUN apk add --no-cache --virtual .frontend-deps nodejs yarn
RUN pip install --no-cache-dir --upgrade pip setuptools wheel

# Disables pip cache. Reduces build time, and suppresses warnings when run as non-root.
# NOTE: MUST be after pip upgrade. Build fails otherwise due to bug in old pip.
ENV PIP_NO_CACHE_DIR true

# Install python requirements
COPY requirements requirements
RUN pip install -r requirements/local.txt -r requirements/deployment.txt

# Remove build dependencies for smaller image
# RUN apk del .build-deps

EXPOSE 8000

ENTRYPOINT ["./docker-entrypoint.sh"]
CMD ["python", "./cfgov/manage.py", "runserver", "0.0.0.0:8000"]

# Build Frontend Assets
FROM cfgov-dev as cfgov-build

ENV STATIC_PATH ${APP_HOME}/cfgov/static/
ENV PYTHONPATH ${APP_HOME}/cfgov

# Django Settings
ENV DJANGO_SETTINGS_MODULE cfgov.settings.production
ENV DJANGO_STATIC_ROOT ${STATIC_PATH}
ENV ALLOWED_HOSTS '["*"]'

# See .dockerignore for details on which files are included
COPY . .

RUN ls -la
# Build the front-end
RUN ./frontend.sh production && \
    cfgov/manage.py collectstatic && \
    yarn cache clean && \
    rm -rf node_modules npm-packages-offline-cache


# Production-like Apache-based image
FROM cfgov-dev as cfgov-prod

ENV HTTPD_ROOT /etc/apache2

# Apache HTTPD settings
ENV APACHE_SERVER_ROOT ${APP_HOME}/cfgov/apache
ENV APACHE_PROCESS_COUNT 4
ENV ACCESS_LOG /dev/stdout
ENV ERROR_LOG /dev/stderr
ENV STATIC_PATH ${APP_HOME}/cfgov/static/
ENV LIMIT_REQUEST_BODY 0

# mod_wsgi settings
ENV CFGOV_PATH ${APP_HOME}
ENV CFGOV_CURRENT ${APP_HOME}
ENV PYTHONPATH ${APP_HOME}/cfgov

# Django Settings
ENV DJANGO_SETTINGS_MODULE cfgov.settings.production
ENV DJANGO_STATIC_ROOT ${STATIC_PATH}
ENV ALLOWED_HOSTS '["*"]'

# Install Apache server, mod_wsgi, and curl (container healthcheck),
# and converts all Docker Secrets into environment variables.
RUN apk add apache2 apache2-mod-wsgi curl && \
    echo '[ -d /var/run/secrets ] && cd /var/run/secrets && for s in *; do export $s=$(cat $s); done && cd -' > /etc/profile.d/secrets_env.sh

# Copy the cfgov directory form the build image
COPY --from=cfgov-build --chown=apache:apache ${CFGOV_PATH}/cfgov ${CFGOV_PATH}/cfgov
COPY --from=cfgov-build --chown=apache:apache ${CFGOV_PATH}/docker-entrypoint.sh ${CFGOV_PATH}/refresh-data.sh ${CFGOV_PATH}/
COPY --from=cfgov-build --chown=apache:apache ${CFGOV_PATH}/static.in ${CFGOV_PATH}/static.in


RUN yum clean all && rm -rf /var/cache/yum && \
    chown -R apache:apache ${APP_HOME} /usr/share/apache2 /var/run/apache2

# Remove files flagged by image vulnerability scanner (doesn't seem to be needed in rh-python38)
#RUN cd /opt/rh/rh-python38/root/usr/lib/python3.8/site-packages/ && \
#    rm -f ndg/httpsclient/test/pki/localhost.key sslserver/certs/development.key

USER apache

# Build frontend, cleanup excess file, and setup filesystem
# - cfgov/f/ - Wagtail file uploads
RUN rm -rf cfgov/apache/www cfgov/unprocessed && \
    mkdir -p cfgov/f

# Healthcheck retry set high since database loads take a while
HEALTHCHECK --start-period=300s --interval=30s --retries=30 \
            CMD curl -sf -A docker-healthcheck -o /dev/null http://localhost:8000

CMD ["httpd", "-d", "cfgov/apache", "-D", "FOREGROUND"]
