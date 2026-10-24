//! The few Windows registry reads and writes the app needs: sign-in
//! entries and Explorer's record of which ones are turned off.

use std::io;
use std::ptr;

use windows_sys::Win32::Foundation::{ERROR_FILE_NOT_FOUND, ERROR_NO_MORE_ITEMS, ERROR_SUCCESS, WIN32_ERROR};
use windows_sys::Win32::System::Registry::{
    HKEY, HKEY_CURRENT_USER, HKEY_LOCAL_MACHINE, KEY_READ, KEY_WOW64_32KEY, REG_EXPAND_SZ, REG_SZ, REG_VALUE_TYPE,
    RRF_RT_REG_BINARY, RRF_RT_REG_SZ, RRF_SUBKEY_WOW6432KEY, RegCloseKey, RegDeleteKeyValueW, RegEnumValueW,
    RegGetValueW, RegOpenKeyExW, RegSetKeyValueW,
};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Hive {
    /// HKEY_CURRENT_USER.
    User,
    /// HKEY_LOCAL_MACHINE, as 64-bit programs see it.
    Machine,
    /// HKEY_LOCAL_MACHINE as 32-bit programs see it (WOW6432Node).
    Machine32,
}

impl Hive {
    fn key(self) -> HKEY {
        match self {
            Hive::User => HKEY_CURRENT_USER,
            Hive::Machine | Hive::Machine32 => HKEY_LOCAL_MACHINE,
        }
    }
}

fn wide(text: &str) -> Vec<u16> {
    text.encode_utf16().chain([0]).collect()
}

fn result(status: WIN32_ERROR) -> io::Result<()> {
    if status == ERROR_SUCCESS { Ok(()) } else { Err(io::Error::from_raw_os_error(status as i32)) }
}

/// Text from UTF-16 bytes, up to the first NUL.
fn text(bytes: &[u8]) -> String {
    let units: Vec<u16> = bytes.as_chunks::<2>().0.iter().map(|pair| u16::from_le_bytes(*pair)).collect();
    let end = units.iter().position(|unit| *unit == 0).unwrap_or(units.len());
    String::from_utf16_lossy(&units[..end])
}

fn read(hive: Hive, subkey: &str, name: &str, restrict: u32) -> Option<Vec<u8>> {
    let (subkey, name) = (wide(subkey), wide(name));
    let flags = restrict | if hive == Hive::Machine32 { RRF_SUBKEY_WOW6432KEY } else { 0 };
    let mut size = 0u32;
    // SAFETY: both names are NUL-terminated and outlive the call; a null buffer asks only for the size.
    let status = unsafe {
        RegGetValueW(hive.key(), subkey.as_ptr(), name.as_ptr(), flags, ptr::null_mut(), ptr::null_mut(), &mut size)
    };
    if status != ERROR_SUCCESS {
        return None;
    }
    let mut buffer = vec![0u8; size as usize];
    // SAFETY: `buffer` holds `size` bytes, as the call is told.
    let status = unsafe {
        RegGetValueW(
            hive.key(),
            subkey.as_ptr(),
            name.as_ptr(),
            flags,
            ptr::null_mut(),
            buffer.as_mut_ptr().cast(),
            &mut size,
        )
    };
    if status != ERROR_SUCCESS {
        return None;
    }
    buffer.truncate(size as usize);
    Some(buffer)
}

/// A text value, with environment variables in an expandable one expanded.
pub fn read_string(hive: Hive, subkey: &str, name: &str) -> Option<String> {
    read(hive, subkey, name, RRF_RT_REG_SZ).map(|bytes| text(&bytes))
}

pub fn read_binary(hive: Hive, subkey: &str, name: &str) -> Option<Vec<u8>> {
    read(hive, subkey, name, RRF_RT_REG_BINARY)
}

fn write(hive: Hive, subkey: &str, name: &str, kind: REG_VALUE_TYPE, data: &[u8]) -> io::Result<()> {
    let (subkey, name) = (wide(subkey), wide(name));
    let length = u32::try_from(data.len()).map_err(|_| io::Error::from(io::ErrorKind::InvalidInput))?;
    // SAFETY: both names are NUL-terminated; `data` holds `length` bytes; all outlive the call.
    result(unsafe { RegSetKeyValueW(hive.key(), subkey.as_ptr(), name.as_ptr(), kind, data.as_ptr().cast(), length) })
}

/// Writes a text value, creating the key if it's missing.
pub fn write_string(hive: Hive, subkey: &str, name: &str, value: &str) -> io::Result<()> {
    let bytes: Vec<u8> = wide(value).into_iter().flat_map(u16::to_le_bytes).collect();
    write(hive, subkey, name, REG_SZ, &bytes)
}

#[cfg(test)]
pub fn write_binary(hive: Hive, subkey: &str, name: &str, value: &[u8]) -> io::Result<()> {
    write(hive, subkey, name, windows_sys::Win32::System::Registry::REG_BINARY, value)
}

/// Deletes a value; one that isn't there is already deleted.
pub fn delete_value(hive: Hive, subkey: &str, name: &str) -> io::Result<()> {
    let (subkey, name) = (wide(subkey), wide(name));
    // SAFETY: both names are NUL-terminated and outlive the call.
    match unsafe { RegDeleteKeyValueW(hive.key(), subkey.as_ptr(), name.as_ptr()) } {
        ERROR_FILE_NOT_FOUND => Ok(()),
        status => result(status),
    }
}

#[cfg(test)]
pub fn delete_tree(hive: Hive, subkey: &str) -> io::Result<()> {
    let subkey = wide(subkey);
    // SAFETY: the name is NUL-terminated and outlives the call.
    result(unsafe { windows_sys::Win32::System::Registry::RegDeleteTreeW(hive.key(), subkey.as_ptr()) })
}

/// A key's text values, by name; an unreadable key has none.
pub fn strings(hive: Hive, subkey: &str) -> Vec<(String, String)> {
    let subkey = wide(subkey);
    let access = KEY_READ | if hive == Hive::Machine32 { KEY_WOW64_32KEY } else { 0 };
    let mut key: HKEY = ptr::null_mut();
    // SAFETY: the name is NUL-terminated and outlives the call; `key` receives the opened handle.
    if unsafe { RegOpenKeyExW(hive.key(), subkey.as_ptr(), 0, access, &mut key) } != ERROR_SUCCESS {
        return Vec::new();
    }
    let mut found = Vec::new();
    let mut name = vec![0u16; 16_384];
    let mut data = vec![0u8; 64 * 1024];
    for index in 0.. {
        let mut name_length = name.len() as u32;
        let mut data_length = data.len() as u32;
        let mut kind: REG_VALUE_TYPE = 0;
        // SAFETY: the buffers hold the lengths passed; `key` is open with read rights.
        let status = unsafe {
            RegEnumValueW(
                key,
                index,
                name.as_mut_ptr(),
                &mut name_length,
                ptr::null(),
                &mut kind,
                data.as_mut_ptr(),
                &mut data_length,
            )
        };
        if status == ERROR_NO_MORE_ITEMS {
            break;
        }
        // A value too long for the buffers isn't a sign-in command anyone wrote by hand; skip it.
        if status != ERROR_SUCCESS {
            continue;
        }
        if kind == REG_SZ || kind == REG_EXPAND_SZ {
            let value_name = String::from_utf16_lossy(&name[..name_length as usize]);
            found.push((value_name, text(&data[..data_length as usize])));
        }
    }
    // SAFETY: `key` was opened above and is closed once.
    unsafe { RegCloseKey(key) };
    found
}

#[cfg(test)]
mod tests {
    use super::{Hive, delete_tree, delete_value, read_binary, read_string, strings, write_binary, write_string};

    #[test]
    fn writes_reads_lists_and_deletes_under_a_test_key() {
        let root = format!(r"Software\OpenTaskManager-tests-{}-registry", std::process::id());
        let key = format!(r"{root}\Values");
        assert_eq!(read_string(Hive::User, &key, "missing"), None);
        write_string(Hive::User, &key, "Text", "C:\\Program Files\\é.exe --x").expect("written");
        write_binary(Hive::User, &key, "Bytes", &[3, 1, 2]).expect("written");
        assert_eq!(read_string(Hive::User, &key, "Text").as_deref(), Some("C:\\Program Files\\é.exe --x"));
        assert_eq!(read_binary(Hive::User, &key, "Bytes"), Some(vec![3, 1, 2]));
        assert_eq!(read_binary(Hive::User, &key, "Text"), None, "a text value isn't bytes");
        assert_eq!(strings(Hive::User, &key), [("Text".to_owned(), "C:\\Program Files\\é.exe --x".to_owned())]);
        delete_value(Hive::User, &key, "Text").expect("deleted");
        delete_value(Hive::User, &key, "Text").expect("a missing value is already deleted");
        assert_eq!(read_string(Hive::User, &key, "Text"), None);
        delete_tree(Hive::User, &root).expect("cleanup");
        assert!(strings(Hive::User, &key).is_empty());
    }
}
