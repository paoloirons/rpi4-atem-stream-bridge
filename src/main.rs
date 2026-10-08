use axum::{
    Json, Router,
    extract::{Path, State},
    http::StatusCode,
    response::{Html, IntoResponse},
    routing::{get, post},
};
use reqwest::Client;
use serde::{Deserialize, Serialize};
use std::{collections::HashMap, env, process::Stdio, sync::Arc, time::Duration};
use tokio::{process::{Child, Command}, sync::Mutex};

const PAGE: &str = include_str!("index.html");

#[derive(Clone)]
struct AppState {
    players: Arc<Mutex<HashMap<String, Player>>>,
    client: Client,
    mediamtx_api: String,
    rtsp_base: String,
}

struct Player {
    child: Child,
    source: String,
}

#[derive(Deserialize)]
struct SelectRequest {
    source: String,
}

#[derive(Deserialize)]
struct PathsResponse {
    items: Option<Vec<PathItem>>,
}

#[derive(Deserialize)]
struct PathItem {
    name: String,
    ready: Option<bool>,
}

#[derive(Serialize)]
struct StatusResponse {
    paths: HashMap<String, bool>,
    outputs: Vec<OutputStatus>,
}

#[derive(Serialize)]
struct OutputStatus {
    id: String,
    label: String,
    source: String,
}

#[tokio::main]
async fn main() {
    let state = AppState {
        players: Arc::new(Mutex::new(HashMap::new())),
        client: Client::builder().timeout(Duration::from_secs(2)).build().expect("HTTP client"),
        mediamtx_api: env::var("MEDIAMTX_API").unwrap_or_else(|_| "http://mediamtx:9997".into()),
        rtsp_base: env::var("RTSP_BASE").unwrap_or_else(|_| "rtsp://mediamtx:8554".into()),
    };

    let app = Router::new()
        .route("/", get(index))
        .route("/api/status", get(status))
        .route("/api/outputs/{output}", post(select_source))
        .with_state(state);

    let listener = tokio::net::TcpListener::bind("0.0.0.0:8080").await.expect("bind panel");
    axum::serve(listener, app).await.expect("serve panel");
}

async fn index() -> Html<&'static str> {
    Html(PAGE)
}

async fn status(State(state): State<AppState>) -> Json<StatusResponse> {
    let mut paths = HashMap::new();
    if let Ok(response) = state.client.get(format!("{}/v3/paths/list", state.mediamtx_api)).send().await {
        if let Ok(data) = response.json::<PathsResponse>().await {
            for path in data.items.unwrap_or_default() {
                paths.insert(path.name, path.ready.unwrap_or(false));
            }
        }
    }

    let mut players = state.players.lock().await;
    let mut finished = Vec::new();
    let mut outputs = Vec::new();
    for (id, label) in [("hdmi0", "HDMI 0"), ("hdmi1", "HDMI 1")] {
        let source = match players.get_mut(id) {
            Some(player) => match player.child.try_wait() {
                Ok(Some(_)) => {
                    finished.push(id.to_string());
                    "stopped".to_string()
                }
                Ok(None) => player.source.clone(),
                Err(_) => "unknown".to_string(),
            },
            None => "idle".to_string(),
        };
        outputs.push(OutputStatus { id: id.into(), label: label.into(), source });
    }
    for id in finished {
        players.remove(&id);
    }
    Json(StatusResponse { paths, outputs })
}

async fn select_source(
    State(state): State<AppState>,
    Path(output): Path<String>,
    Json(request): Json<SelectRequest>,
) -> impl IntoResponse {
    let position = match output.as_str() {
        "hdmi0" => env::var("HDMI0_WINDOW_POS").unwrap_or_else(|_| "0,0".into()),
        "hdmi1" => env::var("HDMI1_WINDOW_POS").unwrap_or_else(|_| "1920,0".into()),
        _ => return (StatusCode::NOT_FOUND, "Unknown HDMI output").into_response(),
    };

    let input = match request.source.as_str() {
        "black" | "cam1" | "cam2" => request.source.as_str(),
        _ => return (StatusCode::BAD_REQUEST, "Choose black, cam1, or cam2").into_response(),
    };

    let mut players = state.players.lock().await;
    if let Some(mut previous) = players.remove(&output) {
        let _ = previous.child.start_kill();
        let _ = previous.child.wait().await;
    }

    let mut command = Command::new("ffplay");
    command.args([
        "-hide_banner", "-loglevel", "warning",
        "-fflags", "nobuffer", "-flags", "low_delay", "-framedrop",
        "-sync", "ext", "-window_title",
    ]);
    command.arg(&output);
    command.arg("-fs");
    if input == "black" {
        command.args(["-an", "-f", "lavfi", "-i", "color=c=black:s=1920x1080:r=50"]);
    } else {
        let url = format!("{}/{}", state.rtsp_base.trim_end_matches('/'), input);
        command.args(["-rtsp_transport", "tcp"]);
        command.arg("-i").arg(url);
    }
    command.env("SDL_VIDEO_WINDOW_POS", position);
    command.stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null());
    match command.spawn() {
        Ok(child) => { players.insert(output, Player { child, source: input.to_string() }); }
        Err(error) => return (StatusCode::INTERNAL_SERVER_ERROR, format!("Could not start FFplay: {error}")).into_response(),
    }

    (StatusCode::OK, "OK").into_response()
}
