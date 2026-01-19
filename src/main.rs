// Function to remove vowels from a string
fn remove_vowels(input: String) -> String {
    let vowels = ['a', 'e', 'i', 'o', 'u', 'A', 'E', 'I', 'O', 'U'];
    input.chars()
        .filter(|c| !vowels.contains(c))
        .collect()
}
// Input struct for /test route
use serde::Deserialize;

#[derive(Deserialize)]
struct VowelInput {
    input: String,
}

// Output struct for /test route
#[derive(Serialize)]
struct VowelOutput {
    output: String,
}

// Handler for /test route
async fn test_remove_vowels(Json(payload): Json<VowelInput>) -> Json<VowelOutput> {
    let output = remove_vowels(payload.input);
    Json(VowelOutput { output })
}
use axum::{
    routing::get,
    Router,
    Json,
};
use serde::Serialize;
use std::net::SocketAddr;
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt};


// 1. Define a structured response object. 
// Using a Struct ensures type safety and prevents leaking sensitive data.
#[derive(Serialize)]
struct ApiResponse {
    message: String,
    status: String,
    timestamp: u64,
}

#[tokio::main]
async fn main() {
    // 2. Initialize Logging (Tracing)
    // This allows you to filter logs via environment variables (RUST_LOG=debug)
    tracing_subscriber::registry()
        .with(tracing_subscriber::EnvFilter::new(
            std::env::var("RUST_LOG").unwrap_or_else(|_| "info".into()),
        ))
        .with(tracing_subscriber::fmt::layer())
        .init();

    // 3. Define Routes
    // Modularity: You can split these into separate files later
    let app = Router::new()
        .route("/health", get(health_check)) // AWS ALB needs this!
        .route("/hello", get(hello_world))
        .route("/test", axum::routing::post(test_remove_vowels));

    // 4. Bind to 0.0.0.0 (Required for Docker)
    let addr = SocketAddr::from(([0, 0, 0, 0], 8080));
    tracing::info!("🚀 Server listening on {}", addr);

    let listener = tokio::net::TcpListener::bind(addr).await.unwrap();
    axum::serve(listener, app).await.unwrap();
}

// Handler: Health Check
// The Load Balancer pings this every 30s. If it fails, the container is killed.
async fn health_check() -> &'static str {
    "OK"
}

// Handler: Business Logic
async fn hello_world() -> Json<ApiResponse> {
    let response = ApiResponse {
        message: "Hello World from Rust Server".to_string(),
        status: "success".to_string(),
        // Just a dummy timestamp
        timestamp: std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs(),
    };

    Json(response)
}