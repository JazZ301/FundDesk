//! macOS 菜单栏报价：按设置组合「上证」、点位数、涨跌幅和当日持仓收益。

use std::cell::RefCell;

use objc2::rc::Retained;
use objc2::{AnyThread, MainThreadMarker, MainThreadOnly};
use objc2_app_kit::{
    NSAutoresizingMaskOptions, NSColor, NSFont, NSFontAttributeName,
    NSForegroundColorAttributeName, NSStatusBarButton, NSTextField, NSView, NSWindowOrderingMode,
};
use objc2_foundation::{NSMutableAttributedString, NSPoint, NSRange, NSRect, NSSize, NSString};
use tauri::tray::TrayIcon;
use tauri::Wry;

const PAD_X: f64 = 5.0;
const GAP: f64 = 4.0;
/// 数字字形比中文字形矮，下移 1pt 让两者的底部落在同一基线。
const NUMBER_Y_OFFSET: f64 = 1.0;

thread_local! {
    static CONTAINER: RefCell<Option<Retained<NSView>>> = const { RefCell::new(None) };
}

#[derive(Clone)]
pub struct Segment {
    pub text: String,
    /// 1 上涨、-1 下跌、0 平盘。
    pub tone: i8,
}

#[derive(Clone)]
pub struct Rows {
    pub prefix: Option<String>,
    pub segments: Vec<Segment>,
}

fn ensure_container(button: &NSStatusBarButton, mtm: MainThreadMarker) -> Retained<NSView> {
    if let Some(container) = CONTAINER.with(|slot| slot.borrow().clone()) {
        if unsafe { container.superview() }.is_some() {
            return container;
        }
    }

    let container = NSView::initWithFrame(NSView::alloc(mtm), button.bounds());
    container.setWantsLayer(true);
    container.setClipsToBounds(true);
    container.setAutoresizingMask(
        NSAutoresizingMaskOptions::ViewWidthSizable | NSAutoresizingMaskOptions::ViewHeightSizable,
    );

    button.setTitle(&NSString::from_str(""));
    // 菜单栏按钮的点击区域由 tray-icon 的覆盖视图处理，显示层放在它下面。
    match button.subviews().into_iter().last() {
        Some(target) => button.addSubview_positioned_relativeTo(
            &container,
            NSWindowOrderingMode::Below,
            Some(&target),
        ),
        None => button.addSubview(&container),
    }
    CONTAINER.with(|slot| *slot.borrow_mut() = Some(container.clone()));
    container
}

fn make_label(text: &str, tone: i8, mtm: MainThreadMarker) -> Retained<NSTextField> {
    let caption = NSString::from_str(text);
    let title =
        NSMutableAttributedString::initWithString(NSMutableAttributedString::alloc(), &caption);
    let font = NSFont::menuBarFontOfSize(0.0);
    let color = match tone {
        1 => NSColor::systemRedColor(),
        -1 => NSColor::systemGreenColor(),
        _ => NSColor::labelColor(),
    };
    unsafe {
        title.addAttribute_value_range(
            NSFontAttributeName,
            &font,
            NSRange::new(0, caption.length()),
        );
        title.addAttribute_value_range(
            NSForegroundColorAttributeName,
            &color,
            NSRange::new(0, caption.length()),
        );
    }

    let label = NSTextField::labelWithString(&NSString::from_str(""), mtm);
    label.setFont(Some(&font));
    label.setDrawsBackground(false);
    label.setBordered(false);
    label.setAttributedStringValue(&title);
    label
}

pub fn set_visible(tray: &TrayIcon<Wry>, visible: bool) {
    let _ = tray.with_inner_tray_icon(move |icon| {
        if let Some(item) = icon.ns_status_item() {
            item.setVisible(visible);
        }
    });
}

pub fn apply(tray: &TrayIcon<Wry>, rows: &Rows) {
    let rows = rows.clone();
    let _ = tray.with_inner_tray_icon(move |icon| {
        let Some(mtm) = MainThreadMarker::new() else {
            return;
        };
        let Some(item) = icon.ns_status_item() else {
            return;
        };
        let Some(button) = item.button(mtm) else {
            return;
        };
        let container = ensure_container(&button, mtm);

        for subview in container.subviews().iter() {
            subview.removeFromSuperview();
        }

        let prefix = rows.prefix.as_deref().map(|text| make_label(text, 0, mtm));
        let labels = rows
            .segments
            .iter()
            .map(|segment| make_label(&segment.text, segment.tone, mtm))
            .collect::<Vec<_>>();

        for label in prefix.iter().chain(labels.iter()) {
            container.addSubview(label);
            label.sizeToFit();
        }

        let prefix_width = prefix
            .as_ref()
            .map(|label| label.frame().size.width)
            .unwrap_or(0.0);
        let label_height = prefix
            .iter()
            .chain(labels.iter())
            .map(|label| label.frame().size.height)
            .fold(0.0_f64, f64::max);

        let mut width = PAD_X * 2.0 + prefix_width;
        if !labels.is_empty() {
            if prefix.is_some() {
                width += GAP;
            }
            width += labels
                .iter()
                .map(|label| label.frame().size.width)
                .sum::<f64>();
            width += GAP * labels.len().saturating_sub(1) as f64;
        }
        item.setLength(width.ceil());

        let bounds = button.bounds();
        for sibling in button.subviews().iter() {
            if !std::ptr::eq(&*sibling, &*container) {
                sibling.setFrame(bounds);
            }
        }
        container.setFrame(bounds);

        let y = (bounds.size.height - label_height) / 2.0;
        let mut x = PAD_X;
        if let Some(label) = &prefix {
            label.setFrame(NSRect::new(
                NSPoint::new(x, y),
                NSSize::new(prefix_width, label_height),
            ));
            x += prefix_width + GAP;
        }
        for label in &labels {
            let label_width = label.frame().size.width;
            label.setFrame(NSRect::new(
                NSPoint::new(x, y - NUMBER_Y_OFFSET),
                NSSize::new(label_width, label_height),
            ));
            x += label_width + GAP;
        }
    });
}
