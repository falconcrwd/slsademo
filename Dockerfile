# syntax=docker/dockerfile:1.7
# Multi-stage build — final image is distroless static so there's almost
# nothing in it besides our binary. Smaller image = easier to reason about
# for provenance.

FROM golang:1.22-alpine AS build
WORKDIR /src
COPY go.mod ./
COPY main.go ./
# Reproducible, static binary.
ENV CGO_ENABLED=0 GOOS=linux GOFLAGS=-trimpath
RUN go build -ldflags="-s -w -buildid=" -o /out/app .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/app /app
USER nonroot:nonroot
EXPOSE 8080
ENTRYPOINT ["/app"]
