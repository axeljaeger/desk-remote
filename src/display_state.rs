extern crate alloc;

use alloc::{rc::Rc, string::String, vec::Vec};
use serde::Deserialize;
use slint::{ComponentHandle, ModelRc, VecModel};

use crate::{AudioDevice, CompanionWindow, MonitorDevice};

#[derive(Deserialize, PartialEq)]
pub(crate) struct Display {
    id: String,
    name: String,
    detail: String,
    brightness: Option<i32>,
}

pub(crate) fn attach(ui: &CompanionWindow) {
    let weak = ui.as_weak();
    ui.on_select_display(move |id| {
        if let Some(ui) = weak.upgrade() {
            ui.set_selected_display(id);
            ui.set_display_message(Default::default());
        }
    });
}

pub(crate) fn apply(
    ui: &CompanionWindow,
    last: &mut Vec<Display>,
    displays: Vec<Display>,
    error: Option<&str>,
) {
    let message = error.unwrap_or(if displays.is_empty() {
        "Keine Monitore verfügbar"
    } else {
        ""
    });
    if ui.get_display_message().as_str() != message {
        ui.set_display_message(message.into());
    }
    if *last == displays {
        return;
    }
    let selected = ui.get_selected_display();
    if !displays
        .iter()
        .any(|display| display.id == selected.as_str())
    {
        ui.set_selected_display(
            displays
                .first()
                .map_or("", |display| display.id.as_str())
                .into(),
        );
    }
    let items: Vec<_> = displays
        .iter()
        .map(|display| AudioDevice {
            id: display.id.as_str().into(),
            name: display.name.as_str().into(),
        })
        .collect();
    let rows: Vec<_> = displays
        .iter()
        .map(|display| MonitorDevice {
            id: display.id.as_str().into(),
            name: display.name.as_str().into(),
            detail: display.detail.as_str().into(),
            brightness: display.brightness.unwrap_or(-1),
        })
        .collect();
    ui.set_display_items(Rc::new(VecModel::from(items)).into());
    ui.set_displays(Rc::new(VecModel::from(rows)).into());
    *last = displays;
}

pub(crate) fn disconnect(ui: &CompanionWindow, last: &mut Vec<Display>, message: &str) {
    if !last.is_empty() {
        last.clear();
        ui.set_display_items(ModelRc::default());
        ui.set_displays(ModelRc::default());
        ui.set_selected_display(Default::default());
    }
    if ui.get_display_message().as_str() != message {
        ui.set_display_message(message.into());
    }
}
