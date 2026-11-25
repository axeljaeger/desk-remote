extern crate alloc;

use alloc::{string::String, vec::Vec};
use serde::{Deserialize, Serialize};
use slint::platform::software_renderer::Rgb565Pixel;
use slint::{ComponentHandle, Image, SharedPixelBuffer};

use crate::{
    CompanionWindow,
    audio_link::send_lan,
    audio_state::{self, Device},
};

const WIDTH: u32 = 480;
const HEIGHT: u32 = 272;
const PORTRAIT_WIDTH: u32 = 304;
const PORTRAIT_HEIGHT: u32 = 544;

unsafe extern "C" {
    fn tab5_video_start(ticket: *const u8, length: u32, prefer_udp: i32, portrait: i32) -> i32;
    fn tab5_video_stop();
    fn tab5_video_take() -> i32;
    fn tab5_video_pixels() -> *const Rgb565Pixel;
    fn tab5_video_status() -> i32;
    fn tab5_camera_blit(
        dest: *mut Rgb565Pixel,
        source: *const Rgb565Pixel,
        left: u32,
        top: u32,
        width: u32,
        height: u32,
        dirty_first: u32,
        dirty_end: u32,
        portrait: i32,
    ) -> i32;
}

pub(crate) struct CameraArea {
    left: u32,
    top: u32,
    width: u32,
    height: u32,
    portrait: bool,
}

impl CameraArea {
    pub(crate) fn draw(&self, back: *mut Rgb565Pixel, dirty_rows: (i32, i32)) -> bool {
        unsafe {
            tab5_camera_blit(
                back,
                tab5_video_pixels(),
                self.left,
                self.top,
                self.width,
                self.height,
                dirty_rows.0 as u32,
                dirty_rows.1 as u32,
                i32::from(self.portrait),
            ) != 0
        }
    }
}

#[derive(Deserialize)]
pub(crate) struct CameraList {
    version: u8,
    cameras: Vec<Device>,
}

#[derive(Deserialize)]
pub(crate) struct CameraReading {
    version: u8,
    status: String,
    ticket: Option<String>,
    message: Option<String>,
    transport: Option<String>,
    layout: Option<String>,
}

#[derive(Serialize)]
struct Command<'a> {
    #[serde(rename = "type")]
    kind: &'static str,
    version: u8,
    #[serde(skip_serializing_if = "Option::is_none")]
    id: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    portrait_camera: Option<bool>,
}

fn request(kind: &'static str, id: Option<&str>) -> bool {
    send_lan(&Command {
        kind,
        version: 1,
        id,
        portrait_camera: (kind == "camera_read").then_some(true),
    })
}

#[derive(Default, Serialize)]
pub(crate) struct CameraTiming {
    render_us: u64,
    copy_us: u64,
    present_us: u64,
    max_gap_us: u64,
    late_frames: u32,
    portrait: bool,
    software: bool,
}

#[derive(Default)]
pub(crate) struct CameraLink {
    devices: Vec<Device>,
    active_id: Option<String>,
    ticket: Option<String>,
    next_list: u64,
    next_read: u64,
    last_frame: u64,
    fps_window: u64,
    frames: i32,
    pub(crate) displayed_frames: u32,
    pub(crate) pending_frame: bool,
    pub(crate) timing: CameraTiming,
    last_present: u64,
    software_prepared: bool,
    hardware_disabled: bool,
}

impl CameraLink {
    pub(crate) fn attach(ui: &CompanionWindow) {
        let weak_ui = ui.as_weak();
        ui.on_select_camera(move |id| {
            if let Some(ui) = weak_ui.upgrade() {
                ui.set_selected_camera(id);
            }
        });
        let weak_ui = ui.as_weak();
        ui.on_toggle_camera(move || {
            if let Some(ui) = weak_ui.upgrade() {
                let running = !ui.get_camera_running();
                ui.set_camera_running(running);
                ui.set_camera_message(if running { "Kamera wird gestartet" } else { "" }.into());
            }
        });
    }

    pub(crate) fn update_list(&mut self, ui: &CompanionWindow, list: CameraList) {
        if list.version != 1 || self.devices == list.cameras {
            return;
        }
        self.devices = list.cameras;
        ui.set_cameras(audio_state::device_model(&self.devices));
    }

    pub(crate) fn update_status(
        &mut self,
        ui: &CompanionWindow,
        id: &str,
        reading: CameraReading,
        now: u64,
    ) {
        if reading.version != 1
            || !ui.get_camera_running()
            || !ui.get_camera_visible()
            || self.active_id.as_deref() != Some(id)
            || ui.get_selected_camera().as_str() != id
        {
            return;
        }
        match reading.status.as_str() {
            "active" => {
                let Some(ticket) = reading.ticket else { return };
                if self.ticket.as_deref() != Some(ticket.as_str()) {
                    let prefer_udp = i32::from(reading.transport.as_deref() == Some("udp"));
                    let portrait = reading.layout.as_deref() == Some("portrait");
                    if unsafe {
                        tab5_video_start(
                            ticket.as_ptr(),
                            ticket.len() as u32,
                            prefer_udp,
                            i32::from(portrait),
                        )
                    } == 0
                    {
                        ui.set_camera_message("Videostream konnte nicht gestartet werden".into());
                        ui.set_camera_running(false);
                        return;
                    }
                    self.ticket = Some(ticket);
                    self.timing.portrait = portrait;
                    self.timing.max_gap_us = 0;
                    self.timing.late_frames = 0;
                    self.timing.software = false;
                    self.last_present = 0;
                    self.hardware_disabled = false;
                    self.pending_frame = false;
                    self.software_prepared = false;
                    ui.set_camera_has_frame(false);
                    ui.set_camera_frame(Image::default());
                    self.last_frame = now;
                    self.fps_window = now;
                    self.frames = 0;
                }
            }
            "starting" | "pending" => {
                ui.set_camera_message(
                    reading
                        .message
                        .as_deref()
                        .unwrap_or("Kamera wird gestartet")
                        .into(),
                );
            }
            _ => {
                ui.set_camera_message(
                    reading
                        .message
                        .as_deref()
                        .unwrap_or("Kamera nicht verfügbar")
                        .into(),
                );
                ui.set_camera_running(false);
            }
        }
    }

    fn clear_frame(&mut self, ui: &CompanionWindow) {
        unsafe { tab5_video_stop() };
        self.ticket = None;
        self.pending_frame = false;
        self.software_prepared = false;
        ui.set_camera_has_frame(false);
        ui.set_camera_frame(Image::default());
        ui.set_camera_fps(0);
    }

    pub(crate) fn poll(&mut self, ui: &CompanionWindow, now: u64) {
        let visible = ui.get_camera_visible();
        if !visible {
            self.next_list = 0;
            ui.set_camera_running(false);
            ui.set_camera_message(Default::default());
        } else if now >= self.next_list && request("camera_list", None) {
            self.next_list = now + 2_000_000;
        }
        let selected = ui.get_selected_camera();
        let device = self
            .devices
            .iter()
            .find(|device| device.id == selected.as_str())
            .or_else(|| self.devices.first());
        if visible {
            let selected = device.map_or("", |device| device.id.as_str());
            let name = device.map_or("", |device| device.name.as_str());
            if ui.get_selected_camera().as_str() != selected {
                ui.set_selected_camera(selected.into());
            }
            if ui.get_camera_name().as_str() != name {
                ui.set_camera_name(name.into());
            }
        }
        let running_id = device
            .filter(|_| visible && ui.get_camera_running())
            .map(|device| device.id.as_str());
        if running_id != self.active_id.as_deref() {
            let next = running_id.map(String::from);
            if next.is_none() && ui.get_network_connected() {
                request("camera_stop", None);
            }
            self.active_id = next;
            self.clear_frame(ui);
            self.next_read = 0;
        }
        if let Some(id) = self.active_id.as_deref()
            && now >= self.next_read
            && request("camera_read", Some(id))
        {
            self.next_read = now + 400_000;
        }
        if self.ticket.is_none() {
            return;
        }
        if unsafe { tab5_video_take() } != 0 {
            self.pending_frame = true;
            self.software_prepared = false;
            if !ui.get_camera_has_frame() {
                ui.set_camera_message(Default::default());
            }
            ui.set_camera_has_frame(true);
            self.last_frame = now;
        }
        if now.saturating_sub(self.fps_window) >= 1_000_000 {
            let elapsed = now - self.fps_window;
            ui.set_camera_fps(
                ((u64::from(self.frames as u32) * 1_000_000 + elapsed / 2) / elapsed) as i32,
            );
            self.fps_window = now;
            self.frames = 0;
        }
        if now.saturating_sub(self.last_frame) > 5_000_000 {
            // These codes correspond to video_status_t in firmware/main/lan.c.
            let message = match unsafe { tab5_video_status() } {
                1 => "JPEG-Decoder konnte nicht starten",
                2 => "WLAN-Verbindung zum Mac fehlgeschlagen",
                3 => "Videoanfrage an den Mac fehlgeschlagen",
                4 => "Mac hat keine Videodaten geliefert",
                5 | 6 => "Unvollständige oder ungültige Videodaten",
                7 => "Videodaten konnten nicht entschlüsselt werden",
                8 => "JPEG-Bildformat ungültig",
                9 => "JPEG-Decoder konnte das Bild nicht lesen",
                _ => "Kein Videobild empfangen",
            };
            ui.set_camera_running(false);
            ui.set_camera_message(message.into());
        }
    }

    pub(crate) fn prepare_display(&mut self, ui: &CompanionWindow) -> Option<CameraArea> {
        let visible_frame =
            ui.get_camera_visible() && ui.get_camera_running() && ui.get_camera_has_frame();
        let use_hardware = visible_frame && !self.hardware_disabled && !ui.get_carousel_moving();
        if ui.get_camera_native_frame() != use_hardware {
            ui.set_camera_native_frame(use_hardware);
            self.software_prepared = false;
            if use_hardware {
                ui.set_camera_frame(Image::default());
            }
        }
        if use_hardware {
            if self.pending_frame {
                ui.window().request_redraw();
            }
            return Some(CameraArea {
                left: ui.get_camera_overlay_x() as u32,
                top: ui.get_camera_overlay_y() as u32,
                width: ui.get_camera_overlay_width() as u32,
                height: ui.get_camera_overlay_height() as u32,
                portrait: self.timing.portrait,
            });
        }
        if visible_frame && !self.software_prepared {
            let portrait = self.timing.portrait;
            let (width, height) = if portrait {
                (PORTRAIT_HEIGHT, PORTRAIT_WIDTH)
            } else {
                (WIDTH, HEIGHT)
            };
            let mut buffer = SharedPixelBuffer::new(width, height);
            let source = unsafe {
                core::slice::from_raw_parts(tab5_video_pixels(), (width * height) as usize)
            };
            if portrait {
                // Undo the Mac's rotation for Slint's logical landscape canvas.
                let width = width as usize;
                let height = height as usize;
                for (y, row) in buffer.make_mut_slice().chunks_exact_mut(width).enumerate() {
                    for (x, dest) in row.iter_mut().enumerate() {
                        *dest = source[(width - 1 - x) * height + y].into();
                    }
                }
            } else {
                for (dest, &pixel) in buffer.make_mut_slice().iter_mut().zip(source) {
                    *dest = pixel.into();
                }
            }
            ui.set_camera_frame(Image::from_rgb8(buffer));
            self.software_prepared = true;
        }
        None
    }

    pub(crate) fn disable_hardware(&mut self, ui: &CompanionWindow) {
        self.hardware_disabled = true;
        self.timing.software = true;
        ui.set_camera_message("Softwaredarstellung aktiv".into());
        self.prepare_display(ui);
    }

    pub(crate) fn presented(&mut self, start: u64, copy: u64, present: u64, end: u64) {
        if core::mem::take(&mut self.pending_frame) {
            self.frames += 1;
            self.displayed_frames = self.displayed_frames.wrapping_add(1);
            self.timing.render_us += copy - start;
            self.timing.copy_us += present - copy;
            self.timing.present_us += end - present;
            if self.last_present != 0 {
                let gap = end - self.last_present;
                self.timing.max_gap_us = self.timing.max_gap_us.max(gap);
                self.timing.late_frames += u32::from(gap > 120_000);
            }
            self.last_present = end;
        }
    }
}
