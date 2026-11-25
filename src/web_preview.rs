use std::cell::RefCell;

use serde::Deserialize;
use wasm_bindgen::prelude::*;

use crate::{
    CompanionWindow,
    audio_state::{self, Incoming, Snapshot},
    display_state,
};

thread_local! {
    static UI: RefCell<Option<CompanionWindow>> = const { RefCell::new(None) };
    static LAST_STATE: RefCell<Option<Snapshot>> = const { RefCell::new(None) };
    static LAST_DISPLAYS: RefCell<Vec<display_state::Display>> = const { RefCell::new(Vec::new()) };
}

pub(crate) fn attach(ui: CompanionWindow) {
    ui.set_browser_preview(true);
    display_state::attach(&ui);
    UI.with(|window| window.replace(Some(ui)));
}

#[wasm_bindgen]
pub fn restore_preview_page(page: i32, changed: js_sys::Function) {
    UI.with_borrow(|ui| {
        if let Some(ui) = ui {
            ui.set_page(page.clamp(0, ui.get_page_count() - 1));
            ui.on_preview_page_changed(move |page| {
                let _ = changed.call1(&JsValue::UNDEFINED, &page.into());
            });
        }
    });
}

#[wasm_bindgen]
pub fn on_audio_selection(handler: js_sys::Function) {
    UI.with_borrow(|ui| {
        if let Some(ui) = ui {
            ui.on_select_audio(move |direction, id| {
                let _ = handler.call2(
                    &JsValue::UNDEFINED,
                    &direction.as_str().into(),
                    &id.as_str().into(),
                );
            });
        }
    });
}

#[wasm_bindgen]
pub fn apply_audio_state(payload: &str) -> Result<(), JsValue> {
    let Ok(Incoming::AudioState { version: 1, audio }) = serde_json::from_str(payload) else {
        return Err(JsValue::from_str("Ungültiger Audiostatus"));
    };
    UI.with_borrow(|ui| {
        if let Some(ui) = ui {
            ui.set_preview(false);
            LAST_STATE.with_borrow_mut(|last| audio_state::apply(ui, last, audio));
        }
    });
    Ok(())
}

#[wasm_bindgen]
pub fn audio_disconnected() {
    UI.with_borrow(|ui| {
        if let Some(ui) = ui.as_ref().filter(|ui| !ui.get_preview()) {
            LAST_STATE.with_borrow_mut(|last| *last = None);
            audio_state::disconnect(ui);
        }
    });
}

#[wasm_bindgen]
pub fn on_meter_toggle(handler: js_sys::Function) {
    UI.with_borrow(|ui| {
        if let Some(ui) = ui {
            ui.on_toggle_meter(move || {
                let _ = handler.call0(&JsValue::UNDEFINED);
            });
        }
    });
}

#[wasm_bindgen]
pub fn meter_visible() -> bool {
    UI.with_borrow(|ui| ui.as_ref().is_some_and(CompanionWindow::get_meter_visible))
}

#[wasm_bindgen]
pub fn set_meter(measuring: bool, rms: i32, peak: i32, clipping: bool, message: &str) {
    UI.with_borrow(|ui| {
        if let Some(ui) = ui {
            ui.set_meter_measuring(measuring);
            ui.set_meter_rms(rms.clamp(-60, 0));
            ui.set_meter_peak(peak.clamp(-60, 0));
            ui.set_meter_clipping(clipping);
            ui.set_meter_message(message.into());
        }
    });
}

#[derive(Deserialize)]
struct CameraList {
    version: u8,
    cameras: Vec<audio_state::Device>,
}

#[wasm_bindgen]
pub fn on_camera_action(select: js_sys::Function, toggle: js_sys::Function) {
    UI.with_borrow(|ui| {
        if let Some(ui) = ui {
            ui.on_select_camera(move |id| {
                let _ = select.call1(&JsValue::UNDEFINED, &id.as_str().into());
            });
            ui.on_toggle_camera(move || {
                let _ = toggle.call0(&JsValue::UNDEFINED);
            });
        }
    });
}

#[wasm_bindgen]
pub fn camera_visible() -> bool {
    UI.with_borrow(|ui| ui.as_ref().is_some_and(CompanionWindow::get_camera_visible))
}

#[wasm_bindgen]
pub fn set_camera_list(payload: &str) -> Result<(), JsValue> {
    let Ok(CameraList {
        version: 1,
        cameras,
    }) = serde_json::from_str(payload)
    else {
        return Err(JsValue::from_str("Ungültige Kameraliste"));
    };
    UI.with_borrow(|ui| {
        if let Some(ui) = ui {
            ui.set_cameras(audio_state::device_model(&cameras));
        }
    });
    Ok(())
}

#[wasm_bindgen]
pub fn set_camera_selection(id: &str, name: &str) {
    UI.with_borrow(|ui| {
        if let Some(ui) = ui {
            ui.set_selected_camera(id.into());
            ui.set_camera_name(name.into());
        }
    });
}

#[wasm_bindgen]
pub fn set_camera_status(running: bool, message: &str) {
    UI.with_borrow(|ui| {
        if let Some(ui) = ui {
            ui.set_camera_running(running);
            ui.set_camera_message(message.into());
        }
    });
}

#[wasm_bindgen]
pub fn camera_overlay_bounds() -> Vec<f32> {
    UI.with_borrow(|ui| {
        ui.as_ref().map_or_else(Vec::new, |ui| {
            vec![
                ui.get_camera_overlay_x(),
                ui.get_camera_overlay_y(),
                ui.get_camera_overlay_width(),
                ui.get_camera_overlay_height(),
            ]
        })
    })
}

#[wasm_bindgen]
pub fn on_media_action(handler: js_sys::Function) {
    UI.with_borrow(|ui| {
        if let Some(ui) = ui {
            ui.on_media_action(move |action| {
                let _ = handler.call1(&JsValue::UNDEFINED, &action.as_str().into());
            });
        }
    });
}

#[wasm_bindgen]
pub fn set_media_message(message: &str) {
    UI.with_borrow(|ui| {
        if let Some(ui) = ui {
            ui.set_media_message(message.into());
        }
    });
}

#[wasm_bindgen]
pub fn on_display_brightness(handler: js_sys::Function) {
    UI.with_borrow(|ui| {
        if let Some(ui) = ui {
            ui.on_set_display_brightness(move |id, brightness| {
                let _ = handler.call2(&JsValue::UNDEFINED, &id.as_str().into(), &brightness.into());
            });
        }
    });
}

#[wasm_bindgen]
pub fn display_visible() -> bool {
    UI.with_borrow(|ui| {
        ui.as_ref()
            .is_some_and(CompanionWindow::get_display_visible)
    })
}

#[wasm_bindgen]
pub fn set_display_state(payload: &str) -> Result<(), JsValue> {
    let Ok(Incoming::DisplayState {
        version: 1,
        displays,
        error,
    }) = serde_json::from_str(payload)
    else {
        return Err(JsValue::from_str("Ungültiger Monitorstatus"));
    };
    UI.with_borrow(|ui| {
        if let Some(ui) = ui {
            LAST_DISPLAYS
                .with_borrow_mut(|last| display_state::apply(ui, last, displays, error.as_deref()));
        }
    });
    Ok(())
}

#[wasm_bindgen]
pub fn display_disconnected() {
    UI.with_borrow(|ui| {
        if let Some(ui) = ui {
            LAST_DISPLAYS.with_borrow_mut(|last| {
                display_state::disconnect(
                    ui,
                    last,
                    "Monitorsteuerung nicht erreichbar. Mac-App prüfen.",
                );
            });
        }
    });
}
