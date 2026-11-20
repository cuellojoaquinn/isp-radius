# freeradius_exporter no publica imagen: se compila desde un tag fijo del repo.
# Upstream: https://github.com/bvantagelimited/freeradius_exporter
FROM golang:1.23.4-alpine AS build
ARG VERSION=0.2.0
RUN apk add --no-cache git
RUN git clone --depth 1 --branch "$VERSION" https://github.com/bvantagelimited/freeradius_exporter /build
WORKDIR /build
RUN CGO_ENABLED=0 go build -o /freeradius_exporter -ldflags "-s -w"

FROM scratch
COPY --from=build /freeradius_exporter /freeradius_exporter
USER 65534
EXPOSE 9812
ENTRYPOINT ["/freeradius_exporter"]
