#![cfg_attr(target_os = "none", no_std)]

#[cfg(target_arch = "wasm32")]
use slint::ComponentHandle;

#[cfg(target_os = "none")]
mod audio_link;
#[cfg(any(target_os = "none", target_arch = "wasm32"))]
mod audio_state;
#[cfg(target_os = "none")]
mod camera_link;
#[cfg(any(target_os = "none", target_arch = "wasm32"))]
mod display_state;
#[cfg(target_os = "none")]
mod page_cache;
#[cfg(target_os = "none")]
mod tab5;
#[cfg(target_os = "none")]
mod ui_test;
#[cfg(target_arch = "wasm32")]
mod web_preview;

slint::include_modules!();

pub fn create_ui() -> Result<CompanionWindow, slint::PlatformError> {
    let ui = CompanionWindow::new()?;
    #[cfg(not(target_os = "none"))]
    ui.set_preview(true);
    Ok(ui)
}

#[cfg(target_arch = "wasm32")]
#[wasm_bindgen::prelude::wasm_bindgen(start)]
pub fn start() -> Result<(), wasm_bindgen::JsValue> {
    let to_js = |error: slint::PlatformError| wasm_bindgen::JsValue::from_str(&error.to_string());
    let ui = create_ui().map_err(to_js)?;
    web_preview::attach(ui.clone_strong());
    ui.run().map_err(to_js)
}
