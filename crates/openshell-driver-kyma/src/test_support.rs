// SPDX-License-Identifier: Apache-2.0

//! Test-only fake Kubernetes API: records every request (method, path, body)
//! and answers with whatever the test's `respond` closure returns.

use std::sync::{Arc, Mutex};

use http_body_util::BodyExt;

#[derive(Debug, Clone)]
pub struct Recorded {
    /// `"<METHOD> <path>"`, e.g. `"PATCH /api/v1/namespaces/ns/services/x"`.
    pub line: String,
    /// The raw (percent-encoded) query string, or empty.
    pub query: String,
    pub body: String,
}

pub fn mock_client<F>(respond: F) -> (kube::Client, Arc<Mutex<Vec<Recorded>>>)
where
    F: Fn(&str) -> (u16, String) + Send + Sync + 'static,
{
    let seen = Arc::new(Mutex::new(Vec::new()));
    let log = Arc::clone(&seen);
    let respond = Arc::new(respond);
    let service = tower::service_fn(move |request: http::Request<kube::client::Body>| {
        let log = Arc::clone(&log);
        let respond = Arc::clone(&respond);
        async move {
            let line = format!("{} {}", request.method(), request.uri().path());
            let query = request.uri().query().unwrap_or_default().to_string();
            let bytes = request
                .into_body()
                .collect()
                .await
                .map(|collected| collected.to_bytes())
                .unwrap_or_default();
            log.lock().unwrap().push(Recorded {
                line: line.clone(),
                query,
                body: String::from_utf8_lossy(&bytes).into_owned(),
            });
            let (status, body) = respond(&line);
            Ok::<_, std::convert::Infallible>(
                http::Response::builder()
                    .status(status)
                    .body(kube::client::Body::from(body.into_bytes()))
                    .unwrap(),
            )
        }
    });
    (kube::Client::new(service, "default"), seen)
}

/// A client whose API server never answers, for timeout tests.
pub fn hanging_client() -> kube::Client {
    let service = tower::service_fn(|_request: http::Request<kube::client::Body>| async {
        std::future::pending::<Result<http::Response<kube::client::Body>, std::convert::Infallible>>()
            .await
    });
    kube::Client::new(service, "default")
}
