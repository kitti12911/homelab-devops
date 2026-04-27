FROM golang:1.26-alpine AS builder
WORKDIR /src
COPY go.mod main.go ./
RUN go mod tidy && \
    CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/grafana-demo .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=builder /out/grafana-demo /grafana-demo
USER nonroot:nonroot
ENTRYPOINT ["/grafana-demo"]
