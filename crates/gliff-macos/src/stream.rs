//! The hardware session: the native helper captures, splits and encodes in
//! one process (see `Streamer` in Gliff.swift) and this side paces it. It
//! grants one encode at a time when the link has room, the way the Linux
//! session paces its encoder, and adapts the bitrate, frame rate, chroma
//! and size with the same estimator, controller and ladder.
use anyhow::{bail, ensure, Context, Result};
use bytes::Bytes;
use gliff_proto::{ChromaMode, ClientCaps, ClientMsg, Codec, ServerMsg};
use gliff_transport::Framed;
use serde_json::{json, Value};
use std::time::{Duration, Instant};
use tokio::io::{AsyncRead, AsyncWrite};
use tokio::process::{ChildStdin, ChildStdout};
use tokio::sync::mpsc;

use crate::native;
use crate::rate::{Ladder, LinkEstimator, RateController};

/// The session-wide frame-rate ceiling; ladder levels cap below it.
const MAX_FPS: u32 = 60;
/// The largest stream VideoToolbox's H.264 encoder takes.
const ENCODER_MAX: (u32, u32) = (4096, 2304);
/// Start at 30 fps, full quality, while the controller measures the link.
const START_LEVEL: usize = 1;
/// Still-picture refinement: at most this many re-encodes of an unchanged
/// screen, at least this far apart.
const MAX_REFINES: u8 = 8;
const REFINE_EVERY: Duration = Duration::from_millis(200);

/// The helper process and what it reported when it started.
pub(crate) struct Native {
    pub child: tokio::process::Child,
    pub stdin: ChildStdin,
    pub stdout: ChildStdout,
    pub output: String,
    /// The display in pixels and in points.
    pub native: (u32, u32),
    pub points: (u32, u32),
}

/// Start the native stream. `Ok(None)` means this Mac has no hardware
/// encoder (or Metal) and the caller should use the CPU path.
pub(crate) async fn spawn(
    output: &str,
    window: (u32, u32),
    dual: bool,
) -> Result<std::result::Result<Native, String>> {
    let fit = fit_extent(window.0, window.1, ENCODER_MAX);
    let ctl = RateController::new(
        fit.0 as u64 * fit.1 as u64,
        if dual { 2 } else { 1 },
        MAX_FPS,
        None,
    );
    let mut child = native::spawn(
        "stream",
        &[
            output.to_string(),
            fit.0.to_string(),
            fit.1.to_string(),
            MAX_FPS.to_string(),
            if dual { "1" } else { "0" }.to_string(),
            ctl.stream_bitrate().to_string(),
            ctl.vbv_ms(30).to_string(),
        ],
    )?;
    let stdin = child.stdin.take().context("missing stream input pipe")?;
    let mut stdout = child.stdout.take().context("missing stream output pipe")?;
    let (kind, ready) = tokio::time::timeout(Duration::from_secs(15), native::read(&mut stdout))
        .await
        .context("screen capture startup timed out")??;
    ensure!(
        kind == native::EVENT,
        "native stream did not identify display"
    );
    let ready: Value = serde_json::from_slice(&ready)?;
    match ready["type"].as_str() {
        Some("ready") => {}
        Some("unsupported") => {
            let _ = child.wait().await;
            return Ok(Err(ready["message"]
                .as_str()
                .unwrap_or("no hardware encoder")
                .to_string()));
        }
        _ => bail!(
            "{}",
            ready["message"].as_str().unwrap_or("screen capture failed")
        ),
    }
    let num = |k: &str| -> Result<u32> {
        Ok(ready[k].as_u64().with_context(|| format!("missing {k}"))? as u32)
    };
    Ok(Ok(Native {
        output: ready["output"]
            .as_str()
            .context("missing display name")?
            .into(),
        native: (num("native_width")?, num("native_height")?),
        points: (num("points_width")?, num("points_height")?),
        child,
        stdin,
        stdout,
    }))
}

/// Scale `(w, h)` down (never up) to fit `max`, keeping even sides.
pub(crate) fn fit_extent(width: u32, height: u32, max: (u32, u32)) -> (u32, u32) {
    if width <= max.0 && height <= max.1 {
        return (width.max(2) & !1, height.max(2) & !1);
    }
    let scale = (max.0 as f64 / width.max(1) as f64).min(max.1 as f64 / height.max(1) as f64);
    let fit = |v: u32| (((v as f64 * scale).floor() as u32) & !1).max(2);
    (fit(width), fit(height))
}

/// The display scaled into the client's window (never up) and the encoder's
/// limit.
fn fit_display(display: (u32, u32), window: (u32, u32)) -> (u32, u32) {
    let fit = (window.0 as f64 / display.0 as f64)
        .min(window.1 as f64 / display.1 as f64)
        .min(1.0);
    fit_extent(
        ((display.0 as f64 * fit).round() as u32).max(2) & !1,
        ((display.1 as f64 * fit).round() as u32).max(2) & !1,
        ENCODER_MAX,
    )
}

/// One coded frame from the helper.
struct Coded {
    keyframe: bool,
    refresh: bool,
    width: u32,
    height: u32,
    scale_milli: u32,
    encode_us: u32,
    main: Bytes,
    aux: Bytes,
}

fn parse_coded(bytes: Vec<u8>) -> Result<Coded> {
    ensure!(bytes.len() >= 28, "truncated native frame");
    let n = |i: usize| u32::from_le_bytes(bytes[i..i + 4].try_into().unwrap());
    let (flags, width, height, scale_milli) = (n(0), n(4), n(8), n(12));
    let (main_len, aux_len, encode_us) = (n(16) as usize, n(20) as usize, n(24));
    ensure!(
        28 + main_len + aux_len == bytes.len(),
        "native frame length mismatch"
    );
    let bytes = Bytes::from(bytes);
    Ok(Coded {
        keyframe: flags & 1 != 0,
        refresh: flags & 2 != 0,
        width,
        height,
        scale_milli,
        encode_us,
        main: bytes.slice(28..28 + main_len),
        aux: bytes.slice(28 + main_len..),
    })
}

/// The StreamConfig for what the helper is actually coding: the client
/// resets its decoder on it, so it follows the frames, not the request.
fn coded_config(p: &Pacer, coded: Option<(u32, u32, u32, bool)>) -> Option<ServerMsg> {
    let (width, height, scale_milli, dual) = coded?;
    Some(ServerMsg::StreamConfig {
        codec: Codec::H264,
        chroma: if dual {
            ChromaMode::Dual420
        } else {
            ChromaMode::Single420
        },
        pipeline: Some(gliff_proto::VideoPipeline::Gpu),
        width,
        height,
        scale_milli,
        extradata: vec![],
        aux_extradata: None,
        // A ladder level that halves the size keeps the full-size view.
        view_width: if p.ladder.level().scale < 1.0 {
            p.base.0
        } else {
            width
        },
        view_height: if p.ladder.level().scale < 1.0 {
            p.base.1
        } else {
            height
        },
        fps_cap: p.fps_cap(),
    })
}

pub(crate) fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

struct Pacer {
    link: LinkEstimator,
    ctl: RateController,
    ladder: Ladder,
    caps: ClientCaps,
    /// The negotiated chroma; a ladder level may drop to Single420.
    base_dual: bool,
    dual: bool,
    window: (u32, u32),
    display: (u32, u32),
    /// The full-quality stream size, and the size the ladder allows.
    base: (u32, u32),
    stream: (u32, u32),
    fps_cmd: u32,
    encode_us: f64,
    granted: bool,
    want_keyframe: bool,
    next_send_at: Instant,
    blocked_noted: bool,
    refines: u8,
    next_refine_at: Instant,
    sent_any: bool,
}

impl Pacer {
    fn fps_cap(&self) -> u32 {
        self.ladder.level().fps_cap.min(MAX_FPS)
    }

    fn update_fps_cmd(&mut self) {
        let sustainable = if self.encode_us > 0.0 {
            (1e6 / (self.encode_us * 1.1)).clamp(5.0, MAX_FPS as f64) as u32
        } else {
            MAX_FPS
        };
        self.fps_cmd = self.fps_cap().min(sustainable).max(1);
    }

    fn can_drop_aux(&self) -> bool {
        self.caps.chroma.contains(&ChromaMode::Single420)
    }

    fn streams(&self) -> u32 {
        if self.dual {
            2
        } else {
            1
        }
    }

    fn byte_cap_has_room(&self, now: Instant) -> bool {
        self.link.inflight_bytes() == 0
            || self.link.inflight_bytes() + self.link.est_frame_bytes()
                <= self.link.cap_bytes(now, self.ctl.is_slow_start())
    }

    fn rate_cmd(&self) -> Value {
        json!({"type": "rate", "bitrate": self.ctl.stream_bitrate(), "fps": self.fps_cmd, "vbv_ms": self.ctl.vbv_ms(self.fps_cmd)})
    }

    /// Derive the stream from the base size and the ladder level. Returns
    /// the helper commands that apply it.
    fn apply_level(&mut self) -> Vec<Value> {
        self.update_fps_cmd();
        let level = self.ladder.level();
        let dual = self.base_dual && (level.aux || !self.can_drop_aux());
        let size = if level.scale < 1.0 {
            fit_extent(
                ((self.base.0 as f64 * level.scale as f64) as u32).max(2),
                ((self.base.1 as f64 * level.scale as f64) as u32).max(2),
                ENCODER_MAX,
            )
        } else {
            self.base
        };
        let mut cmds = Vec::new();
        if dual != self.dual {
            self.dual = dual;
            cmds.push(json!({"type": "chroma", "dual": dual}));
        }
        if size != self.stream {
            self.stream = size;
            cmds.push(json!({"type": "resize", "width": size.0, "height": size.1}));
        }
        self.ctl.reconfigure(
            size.0 as u64 * size.1 as u64,
            self.streams(),
            self.fps_cap(),
        );
        cmds.push(self.rate_cmd());
        cmds
    }
}

pub(crate) async fn run<R, W>(
    mut reader: Framed<R>,
    mut writer: Framed<W>,
    caps: ClientCaps,
    dual: bool,
    fixed_bitrate: Option<u32>,
    native: Native,
) -> Result<()>
where
    R: AsyncRead + Unpin + 'static,
    W: AsyncWrite + Unpin + 'static,
{
    let Native {
        mut child,
        stdin: mut native_writer,
        stdout: mut native_reader,
        output: name,
        native: display,
        points,
    } = native;
    let window = (caps.max_width.max(2), caps.max_height.max(2));
    let base = fit_display(display, window);
    let streams = if dual { 2 } else { 1 };
    let ladder = Ladder::new(START_LEVEL);
    let now = Instant::now();
    let mut p = Pacer {
        link: LinkEstimator::new(),
        ctl: RateController::new(
            base.0 as u64 * base.1 as u64,
            streams,
            MAX_FPS,
            fixed_bitrate,
        ),
        fps_cmd: ladder.level().fps_cap.min(MAX_FPS),
        ladder,
        caps,
        base_dual: dual,
        dual,
        window,
        display,
        base,
        stream: base,
        encode_us: 0.0,
        granted: false,
        want_keyframe: true,
        next_send_at: now,
        blocked_noted: false,
        refines: MAX_REFINES,
        next_refine_at: now,
        sent_any: false,
    };
    let scale_milli = |w: u32| ((w as f64 / points.0.max(1) as f64) * 1000.0).max(1.0) as u32;
    writer
        .write_msg(&ServerMsg::HelloAck {
            version: gliff_proto::PROTOCOL_VERSION,
            session: gliff_proto::SessionInfo {
                headless: false,
                output: name.clone(),
            },
            outputs: vec![gliff_proto::OutputInfo {
                name,
                width: points.0,
                height: points.1,
                scale_milli: scale_milli(display.0),
            }],
            features: gliff_proto::features()
                .into_iter()
                .chain([gliff_proto::FEATURE_CURSOR_IN_VIDEO.to_string()])
                .collect(),
        })
        .await?;
    // Seeds the round-trip estimate before the first frame.
    writer.write_msg(&ServerMsg::Ping { t: now_ms() }).await?;
    // The helper started at the window fit; say where the stream begins.
    let mut cmds = vec![json!({"type": "resize", "width": base.0, "height": base.1})];
    cmds.extend(p.apply_level());
    let mut coded_size: Option<(u32, u32, u32, bool)> = None;

    let (command_tx, mut commands) = mpsc::channel::<Value>(64);
    tokio::task::spawn_local(async move {
        while let Some(cmd) = commands.recv().await {
            native::write(
                &mut native_writer,
                native::EVENT,
                &serde_json::to_vec(&cmd)?,
            )
            .await?;
        }
        Ok::<_, anyhow::Error>(())
    });
    for cmd in cmds {
        command_tx.send(cmd).await?;
    }
    let (frame_tx, mut frames) = mpsc::channel::<Result<(u8, Vec<u8>)>>(2);
    tokio::task::spawn_local(async move {
        loop {
            let frame = native::read(&mut native_reader).await;
            let stopped = frame.is_err();
            if frame_tx.send(frame).await.is_err() || stopped {
                break;
            }
        }
    });
    let (msg_tx, mut input) = mpsc::channel::<Result<(ClientMsg, Bytes)>>(256);
    tokio::task::spawn_local(async move {
        loop {
            let msg = async {
                let msg = reader.read_msg::<ClientMsg>().await?;
                let payload = reader
                    .read_payload(match &msg {
                        ClientMsg::ClipboardData { data_len, .. } => *data_len,
                        _ => 0,
                    })
                    .await?;
                Ok((msg, payload))
            }
            .await;
            let stopped = msg.is_err();
            if msg_tx.send(msg).await.is_err() || stopped {
                break;
            }
        }
    });
    let clipboard = crate::clipboard::Bridge::new(
        gliff_transport::clipboard::Side::Server,
        crate::clipboard::native_commands(command_tx.clone()),
    );
    let mut clips = clipboard.take_outbound();
    let mut frame_id = 0_u64;
    // The client's sound while it has it on: the encoder and the packet count.
    let mut sound: Option<(gliff_audio::Encoder, u32)> = None;
    let result: Result<()> = async {
        loop {
            // Grant the next encode when the link has room and the pace slot
            // is due; a grant stays open until the screen changes.
            let now = Instant::now();
            if !p.granted && now >= p.next_send_at {
                if p.byte_cap_has_room(now) {
                    p.granted = true;
                    command_tx
                        .send(json!({"type": "frame", "keyframe": std::mem::take(&mut p.want_keyframe)}))
                        .await?;
                } else if !p.blocked_noted {
                    p.ctl.note_blocked_at_cap();
                    p.blocked_noted = true;
                }
            }
            let refine_due = p.granted && p.sent_any && p.refines < MAX_REFINES;
            let wake = if refine_due {
                p.next_refine_at
            } else if !p.granted && now < p.next_send_at {
                p.next_send_at
            } else {
                now + Duration::from_secs(3600)
            };
            tokio::select! {
                Some((msg, payload)) = clips.recv() => {
                    writer.write_msg_with_payloads(&ServerMsg::from(msg), &[&payload]).await?;
                }
                _ = tokio::time::sleep_until(tokio::time::Instant::from_std(wake)) => {
                    if refine_due && Instant::now() >= p.next_refine_at {
                        p.refines += 1;
                        p.next_refine_at = Instant::now() + REFINE_EVERY;
                        command_tx.send(json!({"type": "refresh"})).await?;
                    }
                }
                msg = input.recv() => {
                    let Some(msg) = msg else { break };
                    let (msg, payload) = match msg {
                        Ok(m) => m,
                        Err(e) if e.downcast_ref::<gliff_transport::Error>().is_some_and(|e| matches!(e, gliff_transport::Error::Closed)) => break,
                        Err(e) => return Err(e),
                    };
                    let msg = match msg.into_clipboard() {
                        Ok(msg) => { clipboard.peer(msg, payload); continue; }
                        Err(msg) => msg,
                    };
                    match msg {
                        ClientMsg::Bye => break,
                        ClientMsg::FrameAck { frame_id: id, .. } => {
                            let now = Instant::now();
                            p.link.on_ack(now, id);
                            let mut cmds = Vec::new();
                            if let Some(reason) = p.ctl.on_ack(now, &mut p.link) {
                                tracing::debug!(?reason, target = p.ctl.target(), "rate changed");
                                cmds.push(p.rate_cmd());
                            }
                            if !p.granted && p.link.inflight_bytes() == 0 {
                                p.ctl.note_idle(now);
                            }
                            let pixels = p.base.0 as u64 * p.base.1 as u64;
                            let can_drop_aux = p.can_drop_aux();
                            let slow_start = p.ctl.is_slow_start();
                            let congested = p.ctl.congested_recently(now);
                            if let Some(level) = p.ladder.consider(now, &p.link, slow_start, congested, pixels, p.base_dual, can_drop_aux, MAX_FPS) {
                                tracing::info!(level, fps_cap = p.fps_cap(), "ladder step");
                                cmds = p.apply_level();
                                p.want_keyframe = true;
                                if let Some(msg) = coded_config(&p, coded_size) {
                                    writer.write_msg(&msg).await?;
                                }
                            }
                            for cmd in cmds { command_tx.send(cmd).await?; }
                        }
                        ClientMsg::RequestKeyframe => {
                            p.want_keyframe = true;
                            if p.granted {
                                // Answer a still screen with the kept frame.
                                command_tx.send(json!({"type": "frame", "keyframe": true})).await?;
                                command_tx.send(json!({"type": "refresh"})).await?;
                                p.want_keyframe = false;
                            }
                        }
                        ClientMsg::Ping { t } => writer.write_msg(&ServerMsg::Pong { t, server_now_ms: now_ms() }).await?,
                        ClientMsg::Pong { t } => p.link.seed_rtt(Instant::now(), now_ms().saturating_sub(t) as f64),
                        ClientMsg::Audio { enabled } => {
                            if enabled && sound.is_none() {
                                sound = Some((gliff_audio::Encoder::new()?, 0));
                                writer.write_msg(&ServerMsg::AudioStart {
                                    codec: gliff_proto::AudioCodec::Opus,
                                    sample_rate: gliff_audio::SAMPLE_RATE,
                                    channels: gliff_audio::CHANNELS as u32,
                                }).await?;
                            } else if !enabled {
                                sound = None;
                            }
                            tracing::info!(enabled, "audio");
                            command_tx.send(json!({"type": "audio", "enabled": enabled})).await?;
                        }
                        ClientMsg::Resize { width, height, .. } => {
                            let w = width.min(p.caps.max_width) & !1;
                            let h = height.min(p.caps.max_height) & !1;
                            if w >= 320 && h >= 240 {
                                p.window = (w, h);
                                let base = fit_display(p.display, p.window);
                                if base != p.base {
                                    tracing::info!(width = base.0, height = base.1, "scaling the screen to the window");
                                    p.base = base;
                                    for cmd in p.apply_level() { command_tx.send(cmd).await?; }
                                    p.want_keyframe = true;
                                }
                            }
                        }
                        other => if let Some(cmd) = crate::server::input_command(other) { command_tx.send(cmd).await?; },
                    }
                }
                frame = frames.recv() => {
                    let (kind, bytes) = frame.context("capture stopped")??;
                    if kind == native::EVENT {
                        let ev: Value = serde_json::from_slice(&bytes)?;
                        match ev["type"].as_str() {
                            Some("error") => bail!("{}", ev["message"].as_str().unwrap_or("native stream failed")),
                            Some("clipboard") => clipboard.local(&ev).await?,
                            Some("paste") => clipboard.paste(&ev),
                            _ => {}
                        }
                        continue;
                    }
                    if kind == native::AUDIO {
                        if let Some((encoder, seq)) = &mut sound {
                            let pcm: Vec<f32> = bytes.chunks_exact(4).map(|b| f32::from_le_bytes([b[0], b[1], b[2], b[3]])).collect();
                            for packet in encoder.push(&pcm)? {
                                writer.write_msg_with_payloads(&ServerMsg::AudioFrame { seq: *seq, data_len: packet.len() as u32 }, &[&packet]).await?;
                                *seq = seq.wrapping_add(1);
                            }
                        }
                        continue;
                    }
                    ensure!(kind == native::H264, "unknown native stream packet");
                    let coded = parse_coded(bytes)?;
                    p.granted = false;
                    if coded.main.is_empty() {
                        // Nothing coded (a dropped or unavailable surface);
                        // the helper restarts with a keyframe.
                        continue;
                    }
                    let dual_frame = !coded.aux.is_empty();
                    let geometry = (coded.width, coded.height, coded.scale_milli, dual_frame);
                    if Some(geometry) != coded_size {
                        coded_size = Some(geometry);
                        if let Some(msg) = coded_config(&p, coded_size) {
                            writer.write_msg(&msg).await?;
                        }
                    }
                    let now = Instant::now();
                    let total = coded.main.len() + coded.aux.len();
                    let cap = p.link.cap_bytes(now, p.ctl.is_slow_start());
                    let app_limited = coded.refresh
                        || (!p.blocked_noted && p.link.inflight_bytes() + total as u64 + p.link.est_frame_bytes() <= cap);
                    let msg = ServerMsg::VideoFrame {
                        frame_id,
                        pts_us: now_ms() * 1000,
                        keyframe: coded.keyframe,
                        damage: vec![],
                        data_len: coded.main.len() as u32,
                        aux_len: coded.aux.len() as u32,
                    };
                    let t0 = Instant::now();
                    writer.write_msg_with_payloads(&msg, &[&coded.main, &coded.aux]).await?;
                    if t0.elapsed() > Duration::from_secs_f64(1.0 / p.fps_cmd.max(1) as f64) {
                        p.ctl.note_writer_blocked();
                    }
                    p.ctl.note_frame_sent(now);
                    p.link.on_sent(now, frame_id, total, app_limited);
                    frame_id += 1;
                    p.sent_any = true;
                    p.blocked_noted = false;
                    // A keyframe's time includes building the sessions; it
                    // says nothing about the sustainable pace.
                    if !coded.keyframe {
                        p.encode_us = if p.encode_us == 0.0 { coded.encode_us as f64 } else { 0.9 * p.encode_us + 0.1 * coded.encode_us as f64 };
                        let before = p.fps_cmd;
                        p.update_fps_cmd();
                        if (p.fps_cmd as f64 - before as f64).abs() / before.max(1) as f64 > 0.1 {
                            command_tx.send(p.rate_cmd()).await?;
                        } else {
                            p.fps_cmd = before;
                        }
                    }
                    if !coded.refresh {
                        // A new picture: restart still refinement.
                        p.refines = 0;
                        p.next_refine_at = now + REFINE_EVERY;
                        let interval = Duration::from_secs_f64(1.0 / p.fps_cmd.max(1) as f64);
                        p.next_send_at = (p.next_send_at + interval).max(now + interval / 2).min(now + interval);
                    } else {
                        // A refinement that codes small has converged.
                        let done = 0.2 * p.ctl.budget_per_frame(p.fps_cmd) as f64 * p.streams() as f64 / 8.0;
                        if (total as f64) < done { p.refines = MAX_REFINES; }
                    }
                    tracing::debug!(frame_id, key = coded.keyframe, main = coded.main.len(), aux = coded.aux.len(), enc_us = coded.encode_us, "sent frame");
                }
            }
        }
        Ok(())
    }
    .await;
    let _ = command_tx.send(json!({"type": "release"})).await;
    drop(clipboard);
    drop(command_tx);
    let _ = tokio::time::timeout(Duration::from_secs(2), child.wait()).await;
    let _ = child.kill().await;
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fits_the_display_into_the_window_and_the_encoder() {
        assert_eq!(fit_display((3024, 1964), (3840, 2160)), (3024, 1964));
        assert_eq!(fit_display((3024, 1964), (1512, 982)), (1512, 982));
        assert_eq!(fit_display((5120, 2880), (8000, 8000)), (4096, 2304));
        let (w, h) = fit_display((3440, 1440), (1720, 1300));
        assert!(w <= 1720 && h <= 1300 && w % 2 == 0 && h % 2 == 0);
    }

    #[test]
    fn parses_coded_frames() {
        let mut b = Vec::new();
        for n in [3_u32, 64, 32, 2000, 3, 2, 500] {
            b.extend_from_slice(&n.to_le_bytes());
        }
        b.extend_from_slice(&[1, 2, 3, 4, 5]);
        let c = parse_coded(b.clone()).unwrap();
        assert!(c.keyframe && c.refresh);
        assert_eq!(
            (c.width, c.height, c.scale_milli, c.encode_us),
            (64, 32, 2000, 500)
        );
        assert_eq!((&c.main[..], &c.aux[..]), (&[1, 2, 3][..], &[4, 5][..]));
        b.pop();
        assert!(parse_coded(b).is_err());
    }
}
