extern crate alloc;

use alloc::vec::Vec;
use serde::Serialize;
use slint::ComponentHandle;

use crate::{
    CompanionWindow,
    audio_state::{self, Incoming, Snapshot},
    display_state,
};

const PREFIX: &[u8] = b"@tab5 ";
const MAX_LINE: usize = 16 * 1024;
const TIMEOUT_US: u64 = 3_500_000;

unsafe extern "C" {
    fn tab5_serial_read(bytes: *mut u8, capacity: u32) -> i32;
    fn tab5_serial_write(bytes: *const u8, length: usize) -> i32;
    fn tab5_wifi_configure(
        ssid: *const u8,
        ssid_len: u32,
        password: *const u8,
        password_len: u32,
    ) -> i32;
    fn tab5_wifi_status(ipv4: *mut u32) -> i32;
    fn tab5_lan_pair(address: u32, key: *const u8) -> i32;
    fn tab5_lan_ready() -> i32;
    fn tab5_lan_send(bytes: *const u8, length: u32) -> i32;
    fn tab5_lan_receive(bytes: *mut u8, capacity: u32) -> i32;
}

#[derive(Serialize)]
struct Hello {
    #[serde(rename = "type")]
    kind: &'static str,
    version: u8,
    wifi: i32,
    wifi_ip: Option<core::net::Ipv4Addr>,
    lan: bool,
}

#[derive(Serialize)]
struct Selection<'a> {
    #[serde(rename = "type")]
    kind: &'static str,
    version: u8,
    #[serde(skip_serializing_if = "Option::is_none")]
    direction: Option<&'a str>,
    id: &'a str,
}

#[derive(Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum DisplayRequest<'a> {
    DisplayList {
        version: u8,
    },
    DisplayBrightness {
        version: u8,
        id: &'a str,
        brightness: i32,
    },
}

fn send(message: &impl Serialize, over_lan: bool) -> bool {
    let Ok(payload) = serde_json::to_vec(message) else {
        return false;
    };
    if over_lan && unsafe { tab5_lan_ready() != 0 } {
        return unsafe { tab5_lan_send(payload.as_ptr(), payload.len() as u32) } != 0;
    }
    let mut frame = b"\n@tab5 ".to_vec();
    frame.extend_from_slice(&payload);
    frame.push(b'\n');
    unsafe { tab5_serial_write(frame.as_ptr(), frame.len()) == frame.len() as i32 }
}

pub(crate) fn send_lan(message: &impl Serialize) -> bool {
    let Ok(payload) = serde_json::to_vec(message) else {
        return false;
    };
    (unsafe { tab5_lan_send(payload.as_ptr(), payload.len() as u32) }) != 0
}

#[derive(Default)]
pub(crate) struct AudioLink {
    line: Vec<u8>,
    discard_line: bool,
    last_state: Option<Snapshot>,
    last_update_us: u64,
    next_hello_us: u64,
    lan_buffer: Vec<u8>,
    displays: Vec<display_state::Display>,
    displays_available: bool,
    next_displays_us: u64,
    pub(crate) camera: crate::camera_link::CameraLink,
    pub(crate) ui_test: crate::ui_test::UiTestLink,
}

impl AudioLink {
    pub(crate) fn attach(ui: &CompanionWindow) -> Self {
        crate::camera_link::CameraLink::attach(ui);
        display_state::attach(ui);
        let weak_ui = ui.as_weak();
        ui.on_set_display_brightness(move |id, brightness| {
            let Some(ui) = weak_ui.upgrade() else {
                return;
            };
            if !send_lan(&DisplayRequest::DisplayBrightness {
                version: 1,
                id: id.as_str(),
                brightness,
            }) {
                ui.set_display_message("Helligkeit konnte nicht gesendet werden".into());
            }
        });
        let weak_ui = ui.as_weak();
        ui.on_select_audio(move |direction, id| {
            let Some(ui) = weak_ui.upgrade() else { return };
            let command = Selection {
                kind: "select_audio",
                version: 1,
                direction: Some(direction.as_str()),
                id: id.as_str(),
            };
            if !send(&command, true) {
                ui.set_audio_error("Befehl konnte nicht gesendet werden".into());
            }
        });
        let weak_ui = ui.as_weak();
        ui.on_media_action(move |id| {
            let Some(ui) = weak_ui.upgrade() else { return };
            let command = Selection {
                kind: "media_control",
                version: 1,
                direction: None,
                id: id.as_str(),
            };
            ui.set_media_message(
                if send(&command, true) {
                    "Befehl wird gesendet …"
                } else {
                    "Befehl konnte nicht gesendet werden"
                }
                .into(),
            );
        });
        Self::default()
    }

    pub(crate) fn poll(&mut self, ui: &CompanionWindow, now_us: u64) {
        let lan = unsafe { tab5_lan_ready() != 0 };
        if ui.get_network_connected() != lan {
            ui.set_network_connected(lan);
            if !lan {
                display_state::disconnect(ui, &mut self.displays, "");
                self.displays_available = false;
            }
        }
        self.lan_buffer.resize(MAX_LINE, 0);
        let length = unsafe { tab5_lan_receive(self.lan_buffer.as_mut_ptr(), MAX_LINE as u32) };
        if length > 0 {
            match serde_json::from_slice(&self.lan_buffer[..length as usize]) {
                Ok(Incoming::AudioState {
                    version: 1,
                    audio,
                    ui_test_available,
                    displays_available,
                }) => {
                    self.last_update_us = now_us;
                    audio_state::apply(ui, &mut self.last_state, audio);
                    self.ui_test.available = ui_test_available;
                    self.displays_available = displays_available;
                }
                Ok(Incoming::DisplayState {
                    version: 1,
                    displays,
                    error,
                }) if lan => {
                    display_state::apply(ui, &mut self.displays, displays, error.as_deref());
                    self.next_displays_us = now_us + 2_000_000;
                }
                Ok(Incoming::MediaState {
                    version: 1,
                    message,
                }) => ui.set_media_message(message.as_str().into()),
                Ok(Incoming::CameraList { version: 1, list }) => self.camera.update_list(ui, list),
                Ok(Incoming::CameraStatus {
                    version: 1,
                    id: Some(id),
                    reading,
                }) => self.camera.update_status(ui, &id, reading, now_us),
                Ok(Incoming::UiTest {
                    version: 1,
                    command,
                }) => self.ui_test.receive(command),
                _ => {}
            }
        }
        self.camera.poll(ui, now_us);
        if !ui.get_display_visible() {
            self.next_displays_us = 0;
        } else if !self.displays_available {
            display_state::disconnect(
                ui,
                &mut self.displays,
                "Mac-App für die Monitorsteuerung aktualisieren",
            );
        } else if now_us >= self.next_displays_us
            && send_lan(&DisplayRequest::DisplayList { version: 1 })
        {
            self.next_displays_us = now_us + 2_000_000;
        }
        self.ui_test.poll(ui, now_us, &self.camera);
        if now_us >= self.next_hello_us {
            let mut ip = 0;
            let status = unsafe { tab5_wifi_status(&mut ip) };
            let hello = Hello {
                kind: "hello",
                version: 1,
                wifi: status,
                wifi_ip: (status == 2 && ip != 0).then(|| core::net::Ipv4Addr::from(ip)),
                lan,
            };
            send(&hello, false);
            self.next_hello_us = now_us + 1_000_000;
        }
        let mut chunk = [0; 512];
        for _ in 0..4 {
            let count = unsafe { tab5_serial_read(chunk.as_mut_ptr(), chunk.len() as u32) };
            if count <= 0 {
                break;
            }
            for &byte in &chunk[..count as usize] {
                if byte == b'\n' {
                    if !self.discard_line {
                        let line = self.line.strip_suffix(b"\r").unwrap_or(&self.line);
                        if let Some(payload) = line.strip_prefix(PREFIX) {
                            match serde_json::from_slice(payload) {
                                Ok(Incoming::AudioState {
                                    version: 1, audio, ..
                                }) if !lan => {
                                    self.last_update_us = now_us;
                                    audio_state::apply(ui, &mut self.last_state, audio);
                                }
                                Ok(Incoming::WifiConfigure {
                                    version: 1,
                                    ssid,
                                    password,
                                }) => {
                                    unsafe {
                                        tab5_wifi_configure(
                                            ssid.as_ptr(),
                                            ssid.len() as u32,
                                            password.as_ptr(),
                                            password.len() as u32,
                                        )
                                    };
                                }
                                Ok(Incoming::MediaState {
                                    version: 1,
                                    message,
                                }) => {
                                    ui.set_media_message(message.as_str().into());
                                }
                                Ok(Incoming::LanPair {
                                    version: 1,
                                    address,
                                    key,
                                }) => {
                                    unsafe { tab5_lan_pair(address.into(), key.as_ptr()) };
                                }
                                _ => {}
                            }
                        }
                    }
                    self.line.clear();
                    self.discard_line = false;
                } else if self.line.len() == MAX_LINE {
                    self.discard_line = true;
                } else if !self.discard_line {
                    self.line.push(byte);
                }
            }
        }
        if self.last_state.is_some() && now_us.saturating_sub(self.last_update_us) > TIMEOUT_US {
            self.last_state = None;
            audio_state::disconnect(ui);
            ui.set_media_message("Mac-Verbindung getrennt".into());
        }
    }
}
