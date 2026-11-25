extern crate alloc;

use alloc::rc::Rc;
use core::{
    alloc::{GlobalAlloc, Layout},
    cell::Cell,
    panic::PanicInfo,
    time::Duration,
};
use slint::platform::software_renderer::{
    MinimalSoftwareWindow, RenderingRotation, RepaintBufferType, Rgb565Pixel,
};
use slint::platform::{Platform, PlatformError, PointerEventButton, WindowAdapter, WindowEvent};
use slint::{ComponentHandle, LogicalPosition, PhysicalSize};

use crate::page_cache::PageCache;

pub(crate) const LCD_WIDTH: usize = 720;
pub(crate) const LCD_HEIGHT: usize = 1280;

unsafe extern "C" {
    fn tab5_allocate(size: usize, alignment: usize) -> *mut u8;
    fn tab5_free(ptr: *mut u8);
    fn tab5_abort() -> !;
    fn tab5_time_us() -> u64;
    fn tab5_wait();
    fn tab5_present(framebuffer: *const Rgb565Pixel, first_row: i32, end_row: i32);
    fn tab5_touch(x: *mut u16, y: *mut u16) -> i32;
}

struct BoardAllocator;

unsafe impl GlobalAlloc for BoardAllocator {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        unsafe { tab5_allocate(layout.size(), layout.align()) }
    }

    unsafe fn dealloc(&self, ptr: *mut u8, _: Layout) {
        unsafe { tab5_free(ptr) }
    }
}

#[global_allocator]
static ALLOCATOR: BoardAllocator = BoardAllocator;

#[panic_handler]
fn panic(_: &PanicInfo<'_>) -> ! {
    unsafe { tab5_abort() }
}

struct Tab5Platform {
    primary: Rc<MinimalSoftwareWindow>,
    snapshot: Rc<MinimalSoftwareWindow>,
    primary_created: Cell<bool>,
}

impl Platform for Tab5Platform {
    fn create_window_adapter(&self) -> Result<Rc<dyn WindowAdapter>, PlatformError> {
        if self.primary_created.replace(true) {
            Ok(self.snapshot.clone())
        } else {
            Ok(self.primary.clone())
        }
    }

    fn duration_since_start(&self) -> Duration {
        Duration::from_micros(unsafe { tab5_time_us() })
    }
}

#[unsafe(no_mangle)]
extern "C" fn tab5_run_slint(mut front: *mut Rgb565Pixel, mut back: *mut Rgb565Pixel) -> ! {
    let window = MinimalSoftwareWindow::new(RepaintBufferType::SwappedBuffers);
    let snapshot = MinimalSoftwareWindow::new(RepaintBufferType::NewBuffer);
    slint::platform::set_platform(alloc::boxed::Box::new(Tab5Platform {
        primary: window.clone(),
        snapshot: snapshot.clone(),
        primary_created: Cell::new(false),
    }))
    .unwrap();
    let ui = crate::create_ui().unwrap();
    let mut audio_link = crate::audio_link::AudioLink::attach(&ui);
    ui.show().unwrap();
    window.set_size(PhysicalSize::new(LCD_HEIGHT as u32, LCD_WIDTH as u32));

    let mut page_cache = PageCache::new(snapshot);
    let mut front_chrome = None;
    let mut back_chrome = None;
    let mut native_repaint = false;
    let mut camera_composited = false;
    let mut last_touch = None;
    loop {
        slint::platform::update_timers_and_animations();
        audio_link.ui_test.cache_ready = page_cache.as_ref().is_some_and(PageCache::ready);
        audio_link.ui_test.dma_ready = page_cache.as_ref().is_some_and(PageCache::dma_ready);
        audio_link.poll(&ui, unsafe { tab5_time_us() });

        let (mut x, mut y) = (0, 0);
        let touch = unsafe { tab5_touch(&mut x, &mut y) };
        match touch {
            _ if audio_link.ui_test.measuring_swipe() => {}
            1 => {
                // Inverse of the 270° rotation used by the renderer.
                let position = LogicalPosition::new(
                    f32::from(LCD_HEIGHT as u16 - 1 - y.min(LCD_HEIGHT as u16 - 1)),
                    f32::from(x.min(LCD_WIDTH as u16 - 1)),
                );
                let event = if last_touch.replace(position).is_some() {
                    WindowEvent::PointerMoved { position }
                } else {
                    WindowEvent::PointerPressed {
                        position,
                        button: PointerEventButton::Left,
                    }
                };
                ui.window().dispatch_event(event);
            }
            0 => {
                if let Some(position) = last_touch.take() {
                    ui.window().dispatch_event(WindowEvent::PointerReleased {
                        position,
                        button: PointerEventButton::Left,
                    });
                    ui.window().dispatch_event(WindowEvent::PointerExited);
                }
            }
            _ => {} // Leave the current gesture alone on a transient I²C error.
        }
        if last_touch.is_none() {
            audio_link
                .ui_test
                .apply(&ui, front, unsafe { tab5_time_us() });
        }

        let camera_area = audio_link.camera.prepare_display(&ui);
        let software_camera = camera_area.is_none()
            && ui.get_camera_running()
            && ui.get_camera_visible()
            && ui.get_camera_has_frame();
        if camera_area.is_none() && core::mem::take(&mut camera_composited) {
            // The framebuffer can still contain the old video in both buffers.
            native_repaint = true;
        }
        let mut presented = false;
        if native_repaint {
            // Keep ticking the carousel while raw pixel copies bypass Slint's renderer.
            ui.window().request_redraw();
        }
        window.draw_if_needed(|renderer| {
            renderer.set_rendering_rotation(RenderingRotation::Rotate270);
            // ESP-IDF owns both buffers. DMA is reading `front` while we render into `back`.
            let measuring = audio_link.ui_test.measuring_swipe();
            let measure_camera =
                audio_link.camera.pending_frame && (camera_area.is_some() || software_camera);
            let render_start = if measuring || measure_camera {
                unsafe { tab5_time_us() }
            } else {
                0
            };
            let composed = page_cache.as_mut().and_then(|cache| {
                cache.compose(
                    &ui,
                    back,
                    &mut back_chrome,
                    audio_link.ui_test.use_page_cache(),
                    audio_link.ui_test.use_page_dma(),
                )
            });
            let mut rows = if let Some(composition) = &composed {
                native_repaint = true;
                if composition.accelerated && !composition.chrome_copied {
                    // The PPA wrote straight to PSRAM. Only the buffer handoff is needed.
                    (0, 1)
                } else {
                    (0, LCD_HEIGHT as i32)
                }
            } else {
                if core::mem::take(&mut native_repaint) {
                    // The two scanout buffers now contain composited pixels. Rebuild Slint's dirty tracking.
                    renderer.set_repaint_buffer_type(RepaintBufferType::NewBuffer);
                    renderer.set_repaint_buffer_type(RepaintBufferType::SwappedBuffers);
                }
                let pixels =
                    unsafe { core::slice::from_raw_parts_mut(back, LCD_WIDTH * LCD_HEIGHT) };
                let dirty = renderer.render(pixels, LCD_WIDTH);
                if dirty.bounding_box_size().height == 0 {
                    (0, 0)
                } else {
                    back_chrome = None;
                    let first = dirty.bounding_box_origin().y;
                    (first, first + dirty.bounding_box_size().height as i32)
                }
            };
            let mut hardware_camera = false;
            let copy_start = if measure_camera {
                unsafe { tab5_time_us() }
            } else {
                0
            };
            if let Some(area) = &camera_area {
                if area.draw(back, rows) {
                    camera_composited = true;
                    hardware_camera = true;
                    back_chrome = None;
                    // Slint's changed rows were written back before the camera copy.
                    rows = (0, 1);
                } else {
                    audio_link.camera.disable_hardware(&ui);
                }
            }
            if rows.0 == rows.1 {
                return;
            }
            let render_end = if measuring || measure_camera {
                unsafe { tab5_time_us() }
            } else {
                0
            };
            unsafe { tab5_present(back, rows.0, rows.1) };
            core::mem::swap(&mut front, &mut back);
            core::mem::swap(&mut front_chrome, &mut back_chrome);
            presented = true;
            if measure_camera && (hardware_camera || software_camera) {
                audio_link
                    .camera
                    .presented(render_start, copy_start, render_end, unsafe {
                        tab5_time_us()
                    });
            }
            if measuring {
                let end = unsafe { tab5_time_us() };
                audio_link.ui_test.record_frame(
                    render_end - render_start,
                    end - render_end,
                    end,
                    composed.as_ref(),
                );
            }
        });
        if let Some(cache) = page_cache.as_mut()
            && last_touch.is_none()
            && touch == 0
            && !native_repaint
            && !audio_link.ui_test.measuring_swipe()
            && !ui.get_carousel_moving()
            && !ui.window().has_active_animations()
        {
            cache.prepare(&ui, front, unsafe { tab5_time_us() });
        }
        // Present already waits for the display. Only throttle idle polling.
        if !presented || audio_link.ui_test.wait_after_frame() {
            unsafe { tab5_wait() };
        }
    }
}
