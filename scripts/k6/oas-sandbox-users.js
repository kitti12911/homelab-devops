import http from "k6/http";
import { check, sleep } from "k6";

export const options = {
    stages: [
        { duration: "10s", target: 5000 },
        { duration: "1m", target: 5000 },
        { duration: "10s", target: 0 }
    ]
};

export default function () {
    const response = http.get("https://oas-sandbox.lan/health", {
        headers: {
            accept: "application/json",
            "accept-encoding": "gzip"
        },
        tags: {
            api: "GET /health",
            service: "oas-sandbox"
        }
    });

    check(response, {
        "status is 200": (r) => r.status === 200,
        "content-type is json": (r) =>
            (r.headers["Content-Type"] || "").includes("application/json")
    });

    sleep(1);
}
