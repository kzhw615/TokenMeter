#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use tauri::image::Image;
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::Manager;
use tauri_plugin_shell::ShellExt;

const ICON_CALM: &[u8] = include_bytes!("../icons/tray.png");
const ICON_FLAME: &[u8] = include_bytes!("../icons/tray-flame.png");

/// 调用打包的 tokenmeter sidecar（Swift CLI），返回 stdout 文本
#[tauri::command]
async fn run_cli(app: tauri::AppHandle, args: Vec<String>) -> Result<String, String> {
    let sidecar = app
        .shell()
        .sidecar("binaries/tokenmeter")
        .map_err(|e| e.to_string())?
        .args(args);
    let output = sidecar.output().await.map_err(|e| e.to_string())?;
    if output.status.success() {
        Ok(String::from_utf8_lossy(&output.stdout).to_string())
    } else {
        Err(String::from_utf8_lossy(&output.stderr).to_string())
    }
}

/// 切换托盘图标：燃烧火苗 / 默认六边形
#[tauri::command]
fn set_tray_flame(app: tauri::AppHandle, flame: bool) -> Result<(), String> {
    let tray = app.tray_by_id("main").ok_or("tray not found")?;
    let bytes = if flame { ICON_FLAME } else { ICON_CALM };
    let img = Image::from_bytes(bytes).map_err(|e| e.to_string())?;
    tray.set_icon(Some(img)).map_err(|e| e.to_string())?;
    #[cfg(target_os = "macos")]
    let _ = tray.set_icon_as_template(true);
    Ok(())
}

#[tauri::command]
fn quit_app(app: tauri::AppHandle) {
    app.exit(0);
}

fn main() {
    tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .invoke_handler(tauri::generate_handler![run_cli, set_tray_flame, quit_app])
        .setup(|app| {
            let icon = Image::from_bytes(ICON_CALM).expect("tray icon");
            TrayIconBuilder::with_id("main")
                .icon(icon)
                .tooltip("TokenMeter")
                .on_tray_icon_event(|tray, event| {
                    if let TrayIconEvent::Click {
                        button: MouseButton::Left,
                        button_state: MouseButtonState::Up,
                        ..
                    } = event
                    {
                        let app = tray.app_handle();
                        if let Some(win) = app.get_webview_window("main") {
                            if win.is_visible().unwrap_or(false) {
                                let _ = win.hide();
                            } else {
                                let _ = win.show();
                                let _ = win.set_focus();
                            }
                        }
                    }
                })
                .build(app)?;
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
