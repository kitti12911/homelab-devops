import http from "k6/http";
import { check, group, sleep } from "k6";

export const options = {
    stages: [
        { duration: "10s", target: 10000 },
        { duration: "1m", target: 10000 },
        { duration: "10s", target: 0 }
    ]
};

export default function () {
    group("GET /v1/users", () => {
        const response = http.get("https://oas-sandbox.lan/v1/users", {
            headers: {
                accept: "application/json",
                "accept-encoding": "gzip"
            },
            tags: {
                api: "GET /v1/users",
                service: "oas-sandbox"
            }
        });

        const passed = check(response, {
            "status is 200": (r) => r.status === 200,
            "content-type is json": (r) =>
                (r.headers["Content-Type"] || "").includes("application/json")
        });

        if (!passed) {
            logResponseError(response);
        }
    });

    sleep(1);
}

function logResponseError(response) {
    const contentType = response.headers["Content-Type"] || "";
    const requestID =
        response.headers["X-Request-Id"] ||
        response.headers["X-Request-ID"] ||
        response.headers["X-Trace-Id"] ||
        response.headers["X-Trace-ID"] ||
        "";
    const body = response.body ? response.body.slice(0, 500) : "";

    console.error(
        JSON.stringify({
            api: "GET /v1/users",
            error: response.error || "",
            status: response.status,
            contentType,
            requestID,
            body
        })
    );
}
