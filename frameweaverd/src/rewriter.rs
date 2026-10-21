use axum::{
    Json, Router,
    extract::State,
    http::StatusCode,
    routing::{get, post},
};
use reqwest::{Client, Url};
use serde_json::{Value, json};
use std::time::Duration;

const MODELS: [&str; 4] = [
    "frameweaver-rewriter",
    "fw-rewriter-krea2",
    "fw-rewriter-zimage",
    "fw-translate-ja",
];
const RESPONSE_LIMIT: usize = 128 * 1024;
type GatewayError = (StatusCode, Json<Value>);

#[derive(Clone)]
struct Gateway {
    client: Client,
    upstream: Url,
}

fn error(status: StatusCode, message: &'static str) -> GatewayError {
    (status, Json(json!({"error": message})))
}

fn transport(error_value: reqwest::Error) -> GatewayError {
    if error_value.is_timeout() {
        error(StatusCode::GATEWAY_TIMEOUT, "rewriter timeout")
    } else {
        error(StatusCode::BAD_GATEWAY, "rewriter unavailable")
    }
}

async fn read_json(mut response: reqwest::Response) -> Result<Value, GatewayError> {
    if !response.status().is_success() {
        return Err(error(StatusCode::BAD_GATEWAY, "rewriter unavailable"));
    }
    if response
        .content_length()
        .is_some_and(|size| size > RESPONSE_LIMIT as u64)
    {
        return Err(error(StatusCode::BAD_GATEWAY, "response too large"));
    }
    let mut bytes = Vec::new();
    while let Some(chunk) = response.chunk().await.map_err(transport)? {
        if bytes.len() + chunk.len() > RESPONSE_LIMIT {
            return Err(error(StatusCode::BAD_GATEWAY, "response too large"));
        }
        bytes.extend_from_slice(&chunk);
    }
    serde_json::from_slice(&bytes)
        .map_err(|_| error(StatusCode::BAD_GATEWAY, "invalid rewriter response"))
}

pub fn build_router(upstream: Url) -> Result<Router, reqwest::Error> {
    let state = Gateway {
        client: Client::builder()
            .timeout(Duration::from_secs(180))
            .build()?,
        upstream,
    };
    Ok(Router::new()
        .route("/rewriter/models", get(models))
        .route("/rewriter/generate", post(generate))
        .layer(axum::extract::DefaultBodyLimit::max(16 * 1024))
        .with_state(state)
        .layer(axum::middleware::map_response(
            |mut response: axum::response::Response| async move {
                response.headers_mut().insert(
                    axum::http::header::CACHE_CONTROL,
                    axum::http::HeaderValue::from_static("no-store"),
                );
                response
            },
        )))
}

async fn models(State(state): State<Gateway>) -> Result<Json<Value>, GatewayError> {
    let response = state
        .client
        .get(state.upstream.join("/api/tags").expect("static path"))
        .send()
        .await
        .map_err(transport)?;
    let payload = read_json(response).await?;
    let installed = MODELS
        .into_iter()
        .filter(|allowed| {
            payload
                .get("models")
                .and_then(Value::as_array)
                .is_some_and(|items| {
                    items.iter().any(|item| {
                        item.get("name")
                            .and_then(Value::as_str)
                            .is_some_and(|name| {
                                name == *allowed || name.strip_suffix(":latest") == Some(*allowed)
                            })
                    })
                })
        })
        .collect::<Vec<_>>();
    Ok(Json(json!({"models": installed})))
}

fn generation_body(input: Value) -> Result<Value, GatewayError> {
    if !input.is_object() {
        return Err(error(StatusCode::BAD_REQUEST, "invalid json"));
    }
    let model = input
        .get("model")
        .and_then(Value::as_str)
        .filter(|model| MODELS.contains(model))
        .ok_or_else(|| error(StatusCode::FORBIDDEN, "model not allowed"))?;
    let prompt = input
        .get("prompt")
        .and_then(Value::as_str)
        .filter(|prompt| !prompt.trim().is_empty() && prompt.chars().count() <= 8000)
        .ok_or_else(|| error(StatusCode::BAD_REQUEST, "invalid prompt"))?;
    let mut options = serde_json::Map::new();
    for (name, minimum, maximum) in [
        ("temperature", 0.0, 2.0),
        ("top_p", 0.0, 1.0),
        ("top_k", 1.0, 100.0),
        ("num_predict", 1.0, 1200.0),
    ] {
        if let Some(value) = input
            .get("options")
            .and_then(|value| value.get(name))
            .and_then(Value::as_f64)
            .filter(|value| value.is_finite())
        {
            let bounded = value.clamp(minimum, maximum);
            let value = if matches!(name, "top_k" | "num_predict") {
                json!(bounded as u64)
            } else {
                json!(bounded)
            };
            options.insert(name.to_owned(), value);
        }
    }
    Ok(json!({"model": model, "prompt": prompt, "stream": false, "options": options}))
}

async fn generate(
    State(state): State<Gateway>,
    Json(input): Json<Value>,
) -> Result<Json<Value>, GatewayError> {
    let body = generation_body(input)?;
    let response = state
        .client
        .post(state.upstream.join("/api/generate").expect("static path"))
        .json(&body)
        .send()
        .await
        .map_err(transport)?;
    let payload = read_json(response).await?;
    let output = payload
        .get("response")
        .and_then(Value::as_str)
        .ok_or_else(|| error(StatusCode::BAD_GATEWAY, "invalid rewriter response"))?;
    Ok(Json(json!({"response": output})))
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::net::TcpListener;

    async fn serve(router: Router) -> (Url, tokio::task::JoinHandle<()>) {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap())
            .parse()
            .unwrap();
        let task = tokio::spawn(async move {
            axum::serve(listener, router).await.unwrap();
        });
        (url, task)
    }

    #[test]
    fn input_contract_rejects_unknown_models_and_clamps_options() {
        assert_eq!(
            generation_body(Value::Null).unwrap_err().0,
            StatusCode::BAD_REQUEST
        );
        assert_eq!(
            generation_body(json!({"model":"other","prompt":"test"}))
                .unwrap_err()
                .0,
            StatusCode::FORBIDDEN
        );
        let body = generation_body(json!({"model":"fw-rewriter-zimage","prompt":"test","stream":true,"options":{"num_predict":10000,"temperature":-1,"secret":"ignored"}})).unwrap();
        assert_eq!(body["stream"], false);
        assert_eq!(body["options"]["num_predict"].as_u64(), Some(1200));
        assert_eq!(body["options"]["temperature"], 0.0);
        assert!(body["options"].get("secret").is_none());
    }

    #[tokio::test]
    async fn production_routes_filter_models_and_forward_bounded_generation() {
        let upstream = Router::new()
            .route("/api/tags", get(|| async { Json(json!({"models":[{"name":"fw-rewriter-zimage:latest"},{"name":"unrelated"}]})) }))
            .route("/api/generate", post(|Json(body): Json<Value>| async move {
                assert_eq!(body["stream"], false);
                Json(json!({"response":"fixture output"}))
            }));
        let (upstream_url, upstream_task) = serve(upstream).await;
        let (gateway, gateway_task) = serve(build_router(upstream_url).unwrap()).await;
        let client = Client::new();
        let models: Value = client
            .get(gateway.join("/rewriter/models").unwrap())
            .send()
            .await
            .unwrap()
            .json()
            .await
            .unwrap();
        assert_eq!(models, json!({"models":["fw-rewriter-zimage"]}));
        let result = client
            .post(gateway.join("/rewriter/generate").unwrap())
            .json(&json!({"model":"fw-rewriter-zimage","prompt":"a fixture"}))
            .send()
            .await
            .unwrap();
        assert_eq!(result.status(), StatusCode::OK);
        assert_eq!(
            result.json::<Value>().await.unwrap(),
            json!({"response":"fixture output"})
        );
        gateway_task.abort();
        upstream_task.abort();
    }
}
