extern crate alloc;

use alloc::{rc::Rc, string::String, vec::Vec};
use serde::Deserialize;
use slint::{ModelRc, VecModel};

use crate::{AudioDevice, CompanionWindow};

#[derive(Deserialize, PartialEq)]
pub(crate) struct Device {
    pub(crate) id: String,
    pub(crate) name: String,
}

#[derive(Deserialize, PartialEq)]
pub(crate) struct Snapshot {
    inputs: Vec<Device>,
    outputs: Vec<Device>,
    active_input: String,
    active_output: String,
    error: Option<String>,
}

#[derive(Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub(crate) enum Incoming {
    AudioState {
        version: u8,
        audio: Snapshot,
        #[cfg(target_os = "none")]
        #[serde(default)]
        ui_test_available: bool,
        #[cfg(target_os = "none")]
        #[serde(default)]
        displays_available: bool,
    },
    DisplayState {
        version: u8,
        displays: Vec<crate::display_state::Display>,
        error: Option<String>,
    },
    #[cfg(target_os = "none")]
    WifiConfigure {
        version: u8,
        ssid: String,
        password: String,
    },
    #[cfg(target_os = "none")]
    MediaState { version: u8, message: String },
    #[cfg(target_os = "none")]
    LanPair {
        version: u8,
        address: core::net::Ipv4Addr,
        key: [u8; 32],
    },
    #[cfg(target_os = "none")]
    CameraList {
        version: u8,
        list: crate::camera_link::CameraList,
    },
    #[cfg(target_os = "none")]
    CameraStatus {
        version: u8,
        id: Option<String>,
        reading: crate::camera_link::CameraReading,
    },
    #[cfg(target_os = "none")]
    UiTest {
        version: u8,
        command: Option<crate::ui_test::Command>,
    },
}

pub(crate) fn apply(ui: &CompanionWindow, previous: &mut Option<Snapshot>, snapshot: Snapshot) {
    if previous.as_ref() != Some(&snapshot) {
        ui.set_inputs(device_model(&snapshot.inputs));
        ui.set_outputs(device_model(&snapshot.outputs));
        ui.set_active_input(snapshot.active_input.as_str().into());
        ui.set_active_output(snapshot.active_output.as_str().into());
        *previous = Some(snapshot);
    }
    let error = previous.as_ref().and_then(|state| state.error.as_deref());
    ui.set_audio_error(error.unwrap_or_default().into());
    ui.set_connected(true);
}

pub(crate) fn disconnect(ui: &CompanionWindow) {
    ui.set_connected(false);
    ui.set_inputs(ModelRc::default());
    ui.set_outputs(ModelRc::default());
    ui.set_audio_error(Default::default());
}

pub(crate) fn device_model(devices: &[Device]) -> ModelRc<AudioDevice> {
    let rows: Vec<_> = devices
        .iter()
        .map(|device| AudioDevice {
            id: device.id.as_str().into(),
            name: device.name.as_str().into(),
        })
        .collect();
    Rc::new(VecModel::from(rows)).into()
}
