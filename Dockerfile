FROM nginx:1.28-alpine
ARG RELEASE_VERSION=development
ARG SIMULATE_FAULT=false
COPY index.html /usr/share/nginx/html/index.html
COPY health.html /usr/share/nginx/html/health.html
RUN printf '%s\n' "$RELEASE_VERSION" > /usr/share/nginx/html/release.txt \
    && if [ "$SIMULATE_FAULT" = "true" ]; then rm -f /usr/share/nginx/html/health.html; fi
EXPOSE 80
