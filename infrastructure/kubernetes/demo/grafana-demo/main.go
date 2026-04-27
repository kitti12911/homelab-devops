package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"log/slog"
	"math/rand/v2"
	"net/http"
	"net/http/httptest"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/grafana/pyroscope-go"
	"go.opentelemetry.io/contrib/bridges/otelslog"
	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/exporters/otlp/otlplog/otlploghttp"
	"go.opentelemetry.io/otel/exporters/otlp/otlpmetric/otlpmetrichttp"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp"
	otellog "go.opentelemetry.io/otel/log/global"
	"go.opentelemetry.io/otel/metric"
	sdklog "go.opentelemetry.io/otel/sdk/log"
	sdkmetric "go.opentelemetry.io/otel/sdk/metric"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	semconv "go.opentelemetry.io/otel/semconv/v1.27.0"
	"go.opentelemetry.io/otel/trace"
)

const (
	serviceName    = "grafana-demo"
	serviceVersion = "1.0.0"

	tempoEndpoint = "tempo.observability.svc.cluster.local:4318"
	lokiEndpoint  = "loki-gateway.observability.svc.cluster.local:80"
	lokiPath      = "/otlp/v1/logs"
	promEndpoint  = "kube-prometheus-stack-prometheus.observability.svc.cluster.local:9090"
	promPath      = "/api/v1/otlp/v1/metrics"
	pyroEndpoint  = "http://pyroscope.observability.svc.cluster.local:4040"

	runDuration = 60 * time.Second
	tickEvery   = 500 * time.Millisecond
)

func main() {
	rootCtx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()

	res := mustResource()
	shutdown := mustSetup(rootCtx, res)
	defer shutdown()

	logger := otelslog.NewLogger(serviceName)
	tracer := otel.Tracer(serviceName)
	meter := otel.Meter(serviceName)

	reqs, _ := meter.Int64Counter("demo_requests_total",
		metric.WithDescription("Total simulated demo requests"))
	dur, _ := meter.Float64Histogram("demo_request_duration_seconds",
		metric.WithDescription("Simulated demo request duration"),
		metric.WithUnit("s"))
	inflight, _ := meter.Int64UpDownCounter("demo_requests_inflight",
		metric.WithDescription("Inflight simulated requests"))

	srv := startBackend(tracer)
	defer srv.Close()
	client := &http.Client{Transport: otelhttp.NewTransport(http.DefaultTransport)}

	logger.InfoContext(rootCtx, "grafana-demo starting",
		slog.String("tempo", tempoEndpoint),
		slog.String("loki", lokiEndpoint+lokiPath),
		slog.String("prometheus", promEndpoint+promPath),
		slog.String("pyroscope", pyroEndpoint),
		slog.Duration("run_for", runDuration))

	deadline := time.NewTimer(runDuration)
	defer deadline.Stop()
	tick := time.NewTicker(tickEvery)
	defer tick.Stop()

	var iter int64
	for {
		select {
		case <-rootCtx.Done():
			logger.InfoContext(rootCtx, "shutdown requested", slog.Int64("iterations", iter))
			return
		case <-deadline.C:
			logger.InfoContext(rootCtx, "run complete", slog.Int64("iterations", iter))
			return
		case <-tick.C:
			iter++
			runIteration(rootCtx, client, srv.URL, tracer, logger, reqs, dur, inflight, iter)
		}
	}
}

func runIteration(
	ctx context.Context,
	client *http.Client,
	target string,
	tracer trace.Tracer,
	logger *slog.Logger,
	reqs metric.Int64Counter,
	dur metric.Float64Histogram,
	inflight metric.Int64UpDownCounter,
	iter int64,
) {
	ctx, span := tracer.Start(ctx, "runIteration")
	defer span.End()

	start := time.Now()
	inflight.Add(ctx, 1)
	defer inflight.Add(ctx, -1)

	endpoint := pickEndpoint(iter)
	span.SetAttributes(attribute.String("endpoint", endpoint), attribute.Int64("iter", iter))

	burnCPU(20 * time.Millisecond)
	_ = allocate(64 * 1024)

	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, target+endpoint, nil)
	resp, err := client.Do(req)
	status := "ok"
	switch {
	case err != nil:
		status = "client_error"
		logger.ErrorContext(ctx, "request failed",
			slog.Int64("iter", iter),
			slog.String("endpoint", endpoint),
			slog.String("err", err.Error()))
	case resp.StatusCode >= 500:
		status = "server_error"
		resp.Body.Close()
	default:
		resp.Body.Close()
	}

	elapsed := time.Since(start).Seconds()
	attrs := metric.WithAttributes(
		attribute.String("endpoint", endpoint),
		attribute.String("status", status),
	)
	reqs.Add(ctx, 1, attrs)
	dur.Record(ctx, elapsed, attrs)

	if status == "ok" {
		logger.InfoContext(ctx, "iteration ok",
			slog.Int64("iter", iter),
			slog.String("endpoint", endpoint),
			slog.Float64("duration_s", elapsed))
	} else {
		logger.WarnContext(ctx, "iteration "+status,
			slog.Int64("iter", iter),
			slog.String("endpoint", endpoint),
			slog.Float64("duration_s", elapsed))
	}
}

func startBackend(tracer trace.Tracer) *httptest.Server {
	mux := http.NewServeMux()
	mux.Handle("/fast", otelhttp.NewHandler(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		burnCPU(5 * time.Millisecond)
		fmt.Fprintln(w, "fast ok")
	}), "fast"))
	mux.Handle("/slow", otelhttp.NewHandler(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, span := tracer.Start(r.Context(), "slow.work")
		defer span.End()
		burnCPU(80 * time.Millisecond)
		_ = allocate(256 * 1024)
		fmt.Fprintln(w, "slow ok")
	}), "slow"))
	mux.Handle("/flaky", otelhttp.NewHandler(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if rand.IntN(3) == 0 {
			http.Error(w, "boom", http.StatusInternalServerError)
			return
		}
		fmt.Fprintln(w, "flaky ok")
	}), "flaky"))
	return httptest.NewServer(mux)
}

func pickEndpoint(iter int64) string {
	switch iter % 4 {
	case 0:
		return "/slow"
	case 1, 2:
		return "/fast"
	default:
		return "/flaky"
	}
}

func burnCPU(d time.Duration) {
	end := time.Now().Add(d)
	x := 0.0
	for time.Now().Before(end) {
		x += rand.Float64() * rand.Float64()
	}
	_ = x
}

func allocate(n int) []byte {
	b := make([]byte, n)
	for i := range b {
		b[i] = byte(rand.IntN(256))
	}
	return b
}

func mustResource() *resource.Resource {
	r, err := resource.New(context.Background(),
		resource.WithAttributes(
			semconv.ServiceName(serviceName),
			semconv.ServiceVersion(serviceVersion),
			semconv.ServiceNamespace("demo"),
		),
		resource.WithFromEnv(),
		resource.WithHost(),
		resource.WithProcessRuntimeDescription(),
	)
	if err != nil {
		log.Fatalf("resource: %v", err)
	}
	return r
}

func mustSetup(ctx context.Context, res *resource.Resource) func() {
	traceExp, err := otlptracehttp.New(ctx,
		otlptracehttp.WithEndpoint(tempoEndpoint),
		otlptracehttp.WithInsecure(),
	)
	if err != nil {
		log.Fatalf("trace exporter: %v", err)
	}
	tp := sdktrace.NewTracerProvider(
		sdktrace.WithBatcher(traceExp),
		sdktrace.WithResource(res),
		sdktrace.WithSampler(sdktrace.AlwaysSample()),
	)
	otel.SetTracerProvider(tp)

	metricExp, err := otlpmetrichttp.New(ctx,
		otlpmetrichttp.WithEndpoint(promEndpoint),
		otlpmetrichttp.WithURLPath(promPath),
		otlpmetrichttp.WithInsecure(),
	)
	if err != nil {
		log.Fatalf("metric exporter: %v", err)
	}
	mp := sdkmetric.NewMeterProvider(
		sdkmetric.WithReader(sdkmetric.NewPeriodicReader(metricExp,
			sdkmetric.WithInterval(10*time.Second))),
		sdkmetric.WithResource(res),
	)
	otel.SetMeterProvider(mp)

	logExp, err := otlploghttp.New(ctx,
		otlploghttp.WithEndpoint(lokiEndpoint),
		otlploghttp.WithURLPath(lokiPath),
		otlploghttp.WithInsecure(),
	)
	if err != nil {
		log.Fatalf("log exporter: %v", err)
	}
	lp := sdklog.NewLoggerProvider(
		sdklog.WithProcessor(sdklog.NewBatchProcessor(logExp)),
		sdklog.WithResource(res),
	)
	otellog.SetLoggerProvider(lp)

	prof, err := pyroscope.Start(pyroscope.Config{
		ApplicationName: serviceName,
		ServerAddress:   pyroEndpoint,
		Logger:          pyroscope.StandardLogger,
		Tags: map[string]string{
			"service_name": serviceName,
			"namespace":    "demo",
		},
		ProfileTypes: []pyroscope.ProfileType{
			pyroscope.ProfileCPU,
			pyroscope.ProfileAllocObjects,
			pyroscope.ProfileAllocSpace,
			pyroscope.ProfileInuseObjects,
			pyroscope.ProfileInuseSpace,
			pyroscope.ProfileGoroutines,
		},
	})
	if err != nil {
		log.Fatalf("pyroscope: %v", err)
	}

	return func() {
		shutCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		errs := errors.Join(
			tp.Shutdown(shutCtx),
			mp.Shutdown(shutCtx),
			lp.Shutdown(shutCtx),
			prof.Stop(),
		)
		if errs != nil {
			log.Printf("shutdown errors: %v", errs)
		}
	}
}
