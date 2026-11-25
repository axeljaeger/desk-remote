extern crate alloc;

use alloc::rc::Rc;
use core::ptr::NonNull;
use slint::platform::software_renderer::{MinimalSoftwareWindow, RenderingRotation, Rgb565Pixel};
use slint::{ComponentHandle, ModelRc, PhysicalSize, SharedString};

use crate::{
    AudioDevice, CompanionWindow, MonitorDevice,
    tab5::{LCD_HEIGHT, LCD_WIDTH},
};

const PAGE_COUNT: usize = 4;
const PIXELS: usize = LCD_WIDTH * LCD_HEIGHT;
const PREPARE_DELAY_US: u64 = 150_000;

unsafe extern "C" {
    fn tab5_allocate_page_cache(bytes: usize) -> *mut Rgb565Pixel;
    fn tab5_sync_page_cache(pixels: *const Rgb565Pixel) -> i32;
    fn tab5_free(ptr: *mut u8);
    fn tab5_compose_pages(
        dest: *mut Rgb565Pixel,
        chrome: *const Rgb565Pixel,
        strip: *const Rgb565Pixel,
        strip_height: u32,
        source_row: u32,
        top: u32,
        bottom: u32,
        allow_dma: i32,
    ) -> i32;
}

// The live models are replaced when their contents change. ModelRc compares their identity.
#[derive(PartialEq)]
struct Content {
    inputs: ModelRc<AudioDevice>,
    outputs: ModelRc<AudioDevice>,
    cameras: ModelRc<AudioDevice>,
    display_items: ModelRc<AudioDevice>,
    displays: ModelRc<MonitorDevice>,
    selected_display: SharedString,
    display_message: SharedString,
    active_input: SharedString,
    active_output: SharedString,
    audio_error: SharedString,
    media_message: SharedString,
    selected_camera: SharedString,
    camera_name: SharedString,
    camera_message: SharedString,
    connected: bool,
    network_connected: bool,
    input_scroll_y: f32,
    output_scroll_y: f32,
    camera_scroll_y: f32,
    display_scroll_y: f32,
}

impl Content {
    fn read(ui: &CompanionWindow) -> Self {
        Self {
            inputs: ui.get_inputs(),
            outputs: ui.get_outputs(),
            cameras: ui.get_cameras(),
            display_items: ui.get_display_items(),
            displays: ui.get_displays(),
            selected_display: ui.get_selected_display(),
            display_message: ui.get_display_message(),
            active_input: ui.get_active_input(),
            active_output: ui.get_active_output(),
            audio_error: ui.get_audio_error(),
            media_message: ui.get_media_message(),
            selected_camera: ui.get_selected_camera(),
            camera_name: ui.get_camera_name(),
            camera_message: ui.get_camera_message(),
            connected: ui.get_connected(),
            network_connected: ui.get_network_connected(),
            input_scroll_y: ui.get_input_scroll_y(),
            output_scroll_y: ui.get_output_scroll_y(),
            camera_scroll_y: ui.get_camera_scroll_y(),
            display_scroll_y: ui.get_display_scroll_y(),
        }
    }

    fn apply(&self, snapshot: &CompanionWindow) {
        snapshot.set_connected(self.connected);
        snapshot.set_network_connected(self.network_connected);
        snapshot.set_inputs(self.inputs.clone());
        snapshot.set_outputs(self.outputs.clone());
        snapshot.set_cameras(self.cameras.clone());
        snapshot.set_display_items(self.display_items.clone());
        snapshot.set_displays(self.displays.clone());
        snapshot.set_selected_display(self.selected_display.clone());
        snapshot.set_display_message(self.display_message.clone());
        snapshot.set_active_input(self.active_input.clone());
        snapshot.set_active_output(self.active_output.clone());
        snapshot.set_audio_error(self.audio_error.clone());
        snapshot.set_media_message(self.media_message.clone());
        snapshot.set_selected_camera(self.selected_camera.clone());
        snapshot.set_camera_name(self.camera_name.clone());
        snapshot.set_camera_message(self.camera_message.clone());
        snapshot.set_input_scroll_y(self.input_scroll_y);
        snapshot.set_output_scroll_y(self.output_scroll_y);
        snapshot.set_camera_scroll_y(self.camera_scroll_y);
        snapshot.set_display_scroll_y(self.display_scroll_y);
    }
}

pub(crate) struct PageCache {
    pixels: NonNull<Rgb565Pixel>,
    snapshot: CompanionWindow,
    window: Rc<MinimalSoftwareWindow>,
    content: Option<Content>,
    valid: [bool; PAGE_COUNT],
    dma_synced: [bool; PAGE_COUNT],
    prepare_after: u64,
    composing: bool,
    generation: u32,
}

#[derive(Clone, Copy, PartialEq)]
pub(crate) struct Chrome {
    page: usize,
    generation: u32,
}

pub(crate) struct Composition {
    pub(crate) accelerated: bool,
    pub(crate) direct_dma: bool,
    pub(crate) chrome_copied: bool,
}

impl PageCache {
    pub(crate) fn new(window: Rc<MinimalSoftwareWindow>) -> Option<Self> {
        let bytes = PAGE_COUNT * PIXELS * size_of::<Rgb565Pixel>();
        let pixels = NonNull::new(unsafe { tab5_allocate_page_cache(bytes) })?;
        let snapshot = match crate::create_ui().and_then(|snapshot| {
            snapshot.set_snapshot_layout(true);
            snapshot.show()?;
            Ok(snapshot)
        }) {
            Ok(snapshot) => snapshot,
            Err(_) => {
                unsafe { tab5_free(pixels.as_ptr().cast()) };
                return None;
            }
        };
        window.set_size(PhysicalSize::new(LCD_HEIGHT as u32, LCD_WIDTH as u32));
        Some(Self {
            pixels,
            snapshot,
            window,
            content: None,
            valid: [false; PAGE_COUNT],
            dma_synced: [false; PAGE_COUNT],
            prepare_after: 0,
            composing: false,
            generation: 0,
        })
    }

    pub(crate) fn ready(&self) -> bool {
        self.valid.iter().all(|valid| *valid)
    }

    pub(crate) fn dma_ready(&self) -> bool {
        self.ready() && self.dma_synced.iter().all(|synced| *synced)
    }

    fn page(&self, index: usize) -> *mut Rgb565Pixel {
        debug_assert!(index < PAGE_COUNT);
        // Logical X runs opposite to the LCD's physical row order after rotation.
        unsafe { self.pixels.as_ptr().add((PAGE_COUNT - 1 - index) * PIXELS) }
    }

    pub(crate) fn prepare(&mut self, ui: &CompanionWindow, front: *const Rgb565Pixel, now: u64) {
        if ui.get_camera_running() || ui.get_camera_has_frame() {
            self.content = None;
            self.valid.fill(false);
            return;
        }
        let content = Content::read(ui);
        if self.content.as_ref() != Some(&content) {
            content.apply(&self.snapshot);
            self.content = Some(content);
            self.valid.fill(false);
            self.generation = self.generation.wrapping_add(1);
            self.prepare_after = now + PREPARE_DELAY_US;
            return;
        }
        if now < self.prepare_after {
            return;
        }

        let current = ui.get_page() as usize;
        let next = (0..PAGE_COUNT)
            .filter(|&index| !self.valid[index])
            .min_by_key(|&index| index.abs_diff(current));
        let Some(next) = next else {
            return;
        };
        let dest = self.page(next);
        if next == current {
            // The active page is already available in the framebuffer handed to scanout.
            unsafe { core::ptr::copy_nonoverlapping(front, dest, PIXELS) };
            self.valid[next] = true;
        } else {
            self.snapshot.set_page(next as i32);
            self.snapshot.window().request_redraw();
            self.valid[next] = self.window.draw_if_needed(|renderer| {
                renderer.set_rendering_rotation(RenderingRotation::Rotate270);
                let pixels = unsafe { core::slice::from_raw_parts_mut(dest, PIXELS) };
                renderer.render(pixels, LCD_WIDTH);
            });
        }
        if self.valid[next] {
            self.dma_synced[next] = unsafe { tab5_sync_page_cache(dest) } != 0;
        }
    }

    // Returns None when Slint must paint this frame.
    pub(crate) fn compose(
        &mut self,
        ui: &CompanionWindow,
        dest: *mut Rgb565Pixel,
        dest_chrome: &mut Option<Chrome>,
        enabled: bool,
        allow_dma: bool,
    ) -> Option<Composition> {
        let moving = ui.get_carousel_moving();
        let continuing = core::mem::replace(&mut self.composing, false);
        if !enabled
            || (!moving && !continuing)
            || !self.ready()
            || ui.get_camera_running()
            || ui.get_camera_has_frame()
        {
            return None;
        }
        if !moving && self.content.as_ref() != Some(&Content::read(ui)) {
            return None;
        }
        let position = ((-ui.get_carousel_x() + 0.5) as usize).min((PAGE_COUNT - 1) * LCD_HEIGHT);
        let source_row = (PAGE_COUNT - 1) * LCD_HEIGHT - position;
        let top = ui.get_carousel_top() as u32;
        let bottom = ui.get_carousel_bottom() as u32;
        if top >= bottom || bottom > LCD_WIDTH as u32 {
            return None;
        }
        let stamp = Chrome {
            page: ui.get_page() as usize,
            generation: self.generation,
        };
        let chrome_copied = *dest_chrome != Some(stamp);
        let chrome = if chrome_copied {
            self.page(stamp.page).cast_const()
        } else {
            core::ptr::null()
        };
        let backend = unsafe {
            tab5_compose_pages(
                dest,
                chrome,
                self.pixels.as_ptr(),
                (PAGE_COUNT * LCD_HEIGHT) as u32,
                source_row as u32,
                top,
                bottom,
                i32::from(allow_dma && self.dma_ready()),
            )
        };
        *dest_chrome = Some(stamp);
        self.composing = moving;
        Some(Composition {
            accelerated: backend != 0,
            direct_dma: backend == 2,
            chrome_copied,
        })
    }
}

impl Drop for PageCache {
    fn drop(&mut self) {
        unsafe { tab5_free(self.pixels.as_ptr().cast()) };
    }
}
