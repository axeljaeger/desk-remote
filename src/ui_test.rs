extern crate alloc;

use alloc::string::String;
use serde::{Deserialize, Serialize};
use slint::platform::software_renderer::Rgb565Pixel;
use slint::platform::{PointerEventButton, WindowEvent};
use slint::{ComponentHandle, LogicalPosition};

use crate::page_cache::Composition;
use crate::{CompanionWindow, audio_link::send_lan};

unsafe extern "C" {
    fn tab5_screen_capture(front: *const Rgb565Pixel, id: *const u8, length: u32) -> i32;
    fn tab5_screen_status() -> i32;
    fn tab5_video_metrics(out: *mut VideoMetrics);
    fn tab5_wifi_request_test_mode(mode: i32);
    fn tab5_wifi_test_mode() -> i32;
    fn tab5_wifi_power_save() -> i32;
    fn tab5_lan_discoveries() -> u32;
    fn tab5_lan_rediscover();
}

#[derive(Default, Serialize)]
#[repr(C)]
struct VideoMetrics {
    authenticated: u32,
    decoded: u32,
    header_errors: u32,
    invalid_lengths: u32,
    incomplete_records: u32,
    auth_errors: u32,
    jpeg_errors: u32,
    udp_packets: u32,
    udp_frames: u32,
    udp_lost_frames: u32,
    tcp_fallbacks: u32,
    decode_us: u32,
    overwritten: u32,
}

#[derive(Deserialize)]
pub(crate) struct Command {
    id: String,
    action: String,
    x: Option<u16>,
    y: Option<u16>,
    wifi_mode: Option<i32>,
    legacy_wait: Option<bool>,
    use_cache: Option<bool>,
    use_dma: Option<bool>,
}

#[derive(Default, Serialize)]
struct SwipeMetrics {
    frames: u32,
    cached_frames: u32,
    accelerated_frames: u32,
    dma_frames: u32,
    chrome_copies: u32,
    render_us: u64,
    present_us: u64,
    frame_span_us: u64,
    max_frame_gap_us: u64,
}

struct Swipe {
    id: String,
    start: u64,
    from: f32,
    to: f32,
    released: bool,
    legacy_wait: bool,
    use_cache: bool,
    use_dma: bool,
    first_frame: u64,
    last_frame: u64,
    metrics: SwipeMetrics,
}

const SWIPE_DRAG_US: u64 = 300_000;
const SWIPE_MEASUREMENT_US: u64 = 620_000;
const SWIPE_Y: f32 = 230.0;

#[derive(Serialize)]
struct Poll<'a> {
    #[serde(rename = "type")]
    kind: &'static str,
    version: u8,
    ui_state: State<'a>,
}

#[derive(Serialize)]
struct State<'a> {
    ack: Option<&'a str>,
    capture_error: Option<&'static str>,
    page: i32,
    camera_running: bool,
    camera_has_frame: bool,
    camera_fps: i32,
    camera_message: &'a str,
    displayed_frames: u32,
    #[serde(skip_serializing_if = "Option::is_none")]
    camera_timing: Option<&'a crate::camera_link::CameraTiming>,
    video: VideoMetrics,
    wifi_mode: i32,
    #[serde(skip_serializing_if = "Option::is_none")]
    wifi_power_save: Option<bool>,
    lan_discoveries: u32,
    swipe_metrics: Option<&'a SwipeMetrics>,
    swipe_available: bool,
    swipe_cache_ready: bool,
    swipe_strip_cache: bool,
    swipe_dma_ready: bool,
}

#[derive(Default)]
pub(crate) struct UiTestLink {
    pub(crate) available: bool,
    pub(crate) cache_ready: bool,
    pub(crate) dma_ready: bool,
    next_poll: u64,
    command: Option<Command>,
    ack: Option<String>,
    capture_started: bool,
    capture_error: Option<&'static str>,
    swipe: Option<Swipe>,
    swipe_metrics: Option<SwipeMetrics>,
}

impl UiTestLink {
    pub(crate) fn receive(&mut self, command: Option<Command>) {
        self.command = command.filter(|command| {
            self.ack.as_deref() != Some(command.id.as_str())
                && !self
                    .swipe
                    .as_ref()
                    .is_some_and(|swipe| swipe.id == command.id)
        });
    }

    pub(crate) fn poll(
        &mut self,
        ui: &CompanionWindow,
        now: u64,
        camera: &crate::camera_link::CameraLink,
    ) {
        if !self.available || !ui.get_network_connected() || now < self.next_poll {
            return;
        }
        if self.capture_started && unsafe { tab5_screen_status() } < 0 {
            self.capture_error = Some("Screenshot konnte nicht übertragen werden");
        }
        let message = ui.get_camera_message();
        let mut video = VideoMetrics::default();
        unsafe { tab5_video_metrics(&mut video) };
        let poll = Poll {
            kind: "ui_test_poll",
            version: 1,
            ui_state: State {
                ack: self.ack.as_deref(),
                capture_error: self.capture_error,
                page: ui.get_page(),
                camera_running: ui.get_camera_running(),
                camera_has_frame: ui.get_camera_has_frame(),
                camera_fps: ui.get_camera_fps(),
                camera_message: message.as_str(),
                displayed_frames: camera.displayed_frames,
                camera_timing: ui.get_camera_running().then_some(&camera.timing),
                video,
                wifi_mode: unsafe { tab5_wifi_test_mode() },
                wifi_power_save: match unsafe { tab5_wifi_power_save() } {
                    0 => Some(false),
                    1 => Some(true),
                    _ => None,
                },
                lan_discoveries: unsafe { tab5_lan_discoveries() },
                swipe_metrics: self.swipe_metrics.as_ref(),
                swipe_available: true,
                swipe_cache_ready: self.cache_ready,
                swipe_strip_cache: true,
                swipe_dma_ready: self.dma_ready,
            },
        };
        if send_lan(&poll) {
            self.next_poll = now + 500_000;
        }
    }

    pub(crate) fn apply(&mut self, ui: &CompanionWindow, front: *const Rgb565Pixel, now: u64) {
        if let Some(swipe) = self.swipe.as_mut() {
            let elapsed = now.saturating_sub(swipe.start);
            let window = ui.window();
            if elapsed < SWIPE_DRAG_US {
                let progress = elapsed as f32 / SWIPE_DRAG_US as f32;
                let position =
                    LogicalPosition::new(swipe.from + (swipe.to - swipe.from) * progress, SWIPE_Y);
                window.dispatch_event(WindowEvent::PointerMoved { position });
            } else if !swipe.released {
                let position = LogicalPosition::new(swipe.to, SWIPE_Y);
                window.dispatch_event(WindowEvent::PointerMoved { position });
                window.dispatch_event(WindowEvent::PointerReleased {
                    position,
                    button: PointerEventButton::Left,
                });
                window.dispatch_event(WindowEvent::PointerExited);
                swipe.released = true;
            }
            if elapsed >= SWIPE_MEASUREMENT_US {
                let swipe = self.swipe.take().unwrap();
                self.swipe_metrics = Some(swipe.metrics);
                self.ack = Some(swipe.id);
            }
            return;
        }
        let Some(command) = self.command.take() else {
            return;
        };
        self.capture_started = false;
        self.capture_error = None;
        self.swipe_metrics = None;
        match (command.action.as_str(), command.x, command.y) {
            ("tap", Some(x), Some(y)) if x < 1280 && y < 720 => {
                let position = LogicalPosition::new(x.into(), y.into());
                let window = ui.window();
                let button = PointerEventButton::Left;
                window.dispatch_event(WindowEvent::PointerPressed { position, button });
                window.dispatch_event(WindowEvent::PointerReleased { position, button });
                window.dispatch_event(WindowEvent::PointerExited);
            }
            ("capture", _, _) => {
                // The C side copies the current front buffer before returning.
                self.capture_started = unsafe {
                    tab5_screen_capture(front, command.id.as_ptr(), command.id.len() as u32) != 0
                };
                if !self.capture_started {
                    self.capture_error = Some("Screenshot konnte nicht gestartet werden");
                }
            }
            ("wifi_mode", _, _) if !ui.get_camera_running() => {
                let Some(mode @ 0..=2) = command.wifi_mode else {
                    return;
                };
                unsafe { tab5_wifi_request_test_mode(mode) };
            }
            ("lan_rediscover", _, _) if !ui.get_camera_running() => unsafe {
                tab5_lan_rediscover();
            },
            ("swipe_metrics", _, _) if !ui.get_camera_running() => {
                let (from, to) = if ui.get_page() < ui.get_page_count() - 1 {
                    (980.0, 300.0)
                } else {
                    (300.0, 980.0)
                };
                ui.window().dispatch_event(WindowEvent::PointerPressed {
                    position: LogicalPosition::new(from, SWIPE_Y),
                    button: PointerEventButton::Left,
                });
                self.swipe = Some(Swipe {
                    id: command.id,
                    start: now,
                    from,
                    to,
                    released: false,
                    legacy_wait: command.legacy_wait.unwrap_or(false),
                    use_cache: command.use_cache.unwrap_or(false),
                    use_dma: command.use_dma.unwrap_or(true),
                    first_frame: 0,
                    last_frame: 0,
                    metrics: SwipeMetrics::default(),
                });
                return;
            }
            _ => return,
        }
        self.ack = Some(command.id);
    }

    pub(crate) fn measuring_swipe(&self) -> bool {
        self.swipe.is_some()
    }

    pub(crate) fn wait_after_frame(&self) -> bool {
        self.swipe.as_ref().is_some_and(|swipe| swipe.legacy_wait)
    }

    pub(crate) fn use_page_cache(&self) -> bool {
        self.swipe.as_ref().is_none_or(|swipe| swipe.use_cache)
    }

    pub(crate) fn use_page_dma(&self) -> bool {
        self.swipe.as_ref().is_none_or(|swipe| swipe.use_dma)
    }

    pub(crate) fn record_frame(
        &mut self,
        render_us: u64,
        present_us: u64,
        end: u64,
        composed: Option<&Composition>,
    ) {
        let Some(swipe) = self.swipe.as_mut() else {
            return;
        };
        if swipe.metrics.frames == 0 {
            swipe.first_frame = end;
        } else {
            swipe.metrics.max_frame_gap_us =
                swipe.metrics.max_frame_gap_us.max(end - swipe.last_frame);
        }
        swipe.last_frame = end;
        swipe.metrics.frames += 1;
        swipe.metrics.cached_frames += u32::from(composed.is_some());
        swipe.metrics.accelerated_frames +=
            u32::from(composed.is_some_and(|frame| frame.accelerated));
        swipe.metrics.dma_frames += u32::from(composed.is_some_and(|frame| frame.direct_dma));
        swipe.metrics.chrome_copies += u32::from(composed.is_some_and(|frame| frame.chrome_copied));
        swipe.metrics.render_us += render_us;
        swipe.metrics.present_us += present_us;
        swipe.metrics.frame_span_us = end - swipe.first_frame;
    }
}
