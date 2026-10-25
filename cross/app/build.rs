//! Compiles the interface and, for Windows, the program's resources: its
//! icon and the version details Explorer and Task Manager show. The
//! resource file is written here, byte by byte, and handed to the linker
//! (link.exe and lld-link both take a compiled .res), so no resource
//! compiler is needed, cross-compiling from Linux included.

use std::path::Path;
use std::{env, fs};

fn main() {
    slint_build::compile("ui/app.slint").expect("the interface should compile");
    if env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("windows") {
        let icon = Path::new("icons/opentaskmanager.ico");
        println!("cargo:rerun-if-changed={}", icon.display());
        let ico = fs::read(icon).expect("the icon");
        let res = Path::new(&env::var("OUT_DIR").expect("Cargo's OUT_DIR")).join("opentaskmanager.res");
        fs::write(&res, resources(&ico, &env::var("CARGO_PKG_VERSION").expect("a version")))
            .expect("the resource file");
        println!("cargo:rustc-link-arg-bins={}", res.display());
    }
}

const RT_ICON: u16 = 3;
const RT_GROUP_ICON: u16 = 14;
const RT_VERSION: u16 = 16;
const ENGLISH_US: u16 = 0x0409;

fn pad(out: &mut Vec<u8>) {
    while !out.len().is_multiple_of(4) {
        out.push(0);
    }
}

fn wide(text: &str) -> Vec<u8> {
    text.encode_utf16().chain([0]).flat_map(u16::to_le_bytes).collect()
}

/// One resource, typed and named by number.
fn entry(out: &mut Vec<u8>, kind: u16, id: u16, flags: u16, data: &[u8]) {
    out.extend((data.len() as u32).to_le_bytes());
    out.extend(32u32.to_le_bytes());
    out.extend([0xFF, 0xFF]);
    out.extend(kind.to_le_bytes());
    out.extend([0xFF, 0xFF]);
    out.extend(id.to_le_bytes());
    out.extend(0u32.to_le_bytes());
    out.extend(flags.to_le_bytes());
    out.extend(if kind == 0 { 0 } else { ENGLISH_US }.to_le_bytes());
    out.extend([0; 8]);
    out.extend(data);
    pad(out);
}

fn resources(ico: &[u8], version: &str) -> Vec<u8> {
    let mut out = Vec::new();
    // A resource file opens with an empty entry.
    entry(&mut out, 0, 0, 0, &[]);

    // Each image as an icon resource, then the group that lists them.
    let u16_at = |at: usize| u16::from_le_bytes([ico[at], ico[at + 1]]);
    let u32_at = |at: usize| u32::from_le_bytes([ico[at], ico[at + 1], ico[at + 2], ico[at + 3]]);
    let count = u16_at(4);
    let mut group = Vec::new();
    group.extend([0, 0, 1, 0]);
    group.extend(count.to_le_bytes());
    for index in 0..count {
        let at = 6 + 16 * usize::from(index);
        let (size, offset) = (u32_at(at + 8) as usize, u32_at(at + 12) as usize);
        entry(&mut out, RT_ICON, index + 1, 0x1010, &ico[offset..offset + size]);
        group.extend(&ico[at..at + 8]);
        group.extend((size as u32).to_le_bytes());
        group.extend((index + 1).to_le_bytes());
    }
    entry(&mut out, RT_GROUP_ICON, 1, 0x1030, &group);
    entry(&mut out, RT_VERSION, 1, 0x0030, &version_info(version));
    out
}

enum Value<'a> {
    Nothing,
    Bytes(&'a [u8]),
    Text(&'a str),
}

/// One node of a version resource: its length, its value's, its kind,
/// its key, its value and its children, each aligned to four bytes.
fn node(key: &str, value: Value, children: &[Vec<u8>]) -> Vec<u8> {
    let (value_bytes, value_length, text) = match value {
        Value::Nothing => (Vec::new(), 0, true),
        Value::Bytes(bytes) => (bytes.to_vec(), bytes.len(), false),
        Value::Text(text) => {
            let bytes = wide(text);
            let units = bytes.len() / 2;
            (bytes, units, true)
        }
    };
    let mut out = vec![0, 0];
    out.extend((value_length as u16).to_le_bytes());
    out.extend(u16::from(text).to_le_bytes());
    out.extend(wide(key));
    pad(&mut out);
    out.extend(value_bytes);
    for child in children {
        pad(&mut out);
        out.extend(child);
    }
    let length = out.len() as u16;
    out[..2].copy_from_slice(&length.to_le_bytes());
    out
}

fn version_info(version: &str) -> Vec<u8> {
    let parts: Vec<u16> = version.split(['.', '-']).filter_map(|part| part.parse().ok()).chain([0; 4]).take(4).collect();
    let (high, low) = (
        u32::from(parts[0]) << 16 | u32::from(parts[1]),
        u32::from(parts[2]) << 16 | u32::from(parts[3]),
    );
    let mut fixed = Vec::new();
    for field in [0xFEEF_04BDu32, 0x0001_0000, high, low, high, low, 0x3F, 0, 0x0004_0004, 1, 0, 0, 0] {
        fixed.extend(field.to_le_bytes());
    }
    let strings: Vec<Vec<u8>> = [
        ("CompanyName", "OpenTaskManager"),
        ("FileDescription", "OpenTaskManager"),
        ("FileVersion", version),
        ("InternalName", "opentaskmanager"),
        ("LegalCopyright", "Free software under the GNU GPL, version 3"),
        ("OriginalFilename", "opentaskmanager.exe"),
        ("ProductName", "OpenTaskManager"),
        ("ProductVersion", version),
    ]
    .iter()
    .map(|(key, value)| node(key, Value::Text(value), &[]))
    .collect();
    let table = node("040904B0", Value::Nothing, &strings);
    let string_info = node("StringFileInfo", Value::Nothing, &[table]);
    let translation = node("Translation", Value::Bytes(&[0x09, 0x04, 0xB0, 0x04]), &[]);
    let var_info = node("VarFileInfo", Value::Nothing, &[translation]);
    node("VS_VERSION_INFO", Value::Bytes(&fixed), &[string_info, var_info])
}
