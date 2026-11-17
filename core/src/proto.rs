//! Hand-rolled decoding for the tiny `scrcpy.proto` subset we need.

fn varint(data: &[u8], index: &mut usize) -> Option<u64> {
    let mut result: u64 = 0;
    let mut shift = 0;
    while *index < data.len() {
        let byte = data[*index];
        *index += 1;
        result |= ((byte & 0x7f) as u64) << shift;
        if byte & 0x80 == 0 {
            return Some(result);
        }
        shift += 7;
        if shift > 63 {
            return None;
        }
    }
    None
}

fn skip(data: &[u8], index: &mut usize, wire: u64) -> bool {
    match wire {
        0 => varint(data, index).is_some(),
        1 => {
            if data.len() - *index < 8 {
                return false;
            }
            *index += 8;
            true
        }
        2 => match varint(data, index) {
            Some(len) if len as usize <= data.len() - *index => {
                *index += len as usize;
                true
            }
            _ => false,
        },
        5 => {
            if data.len() - *index < 4 {
                return false;
            }
            *index += 4;
            true
        }
        _ => false,
    }
}

fn bytes_field<'a>(data: &'a [u8], index: &mut usize) -> Option<&'a [u8]> {
    let len = varint(data, index)? as usize;
    if len > data.len() - *index {
        return None;
    }
    let start = *index;
    *index += len;
    Some(&data[start..*index])
}

/// Returns `payload["data"].val_bytes` from a `ReplyMessage`.
pub fn reply_data(message: &[u8]) -> Option<Vec<u8>> {
    let mut index = 0;
    let mut found: Option<Vec<u8>> = None;
    while index < message.len() {
        let tag = varint(message, &mut index)?;
        let field = tag >> 3;
        let wire = tag & 0x7;
        if field == 3 && wire == 2 {
            let entry = bytes_field(message, &mut index)?;
            if let Some(data) = payload_data(entry) {
                found = Some(data);
            }
        } else if !skip(message, &mut index, wire) {
            break;
        }
    }
    found
}

fn payload_data(entry: &[u8]) -> Option<Vec<u8>> {
    let mut index = 0;
    let mut key: Option<&[u8]> = None;
    let mut value: Option<&[u8]> = None;
    while index < entry.len() {
        let tag = varint(entry, &mut index)?;
        let field = tag >> 3;
        let wire = tag & 0x7;
        if field == 1 && wire == 2 {
            key = bytes_field(entry, &mut index);
        } else if field == 2 && wire == 2 {
            value = bytes_field(entry, &mut index);
        } else if !skip(entry, &mut index, wire) {
            break;
        }
    }
    if key != Some(b"data") {
        return None;
    }
    let value = value?;
    let mut index = 0;
    while index < value.len() {
        let tag = varint(value, &mut index)?;
        let field = tag >> 3;
        let wire = tag & 0x7;
        if field == 5 && wire == 2 {
            return bytes_field(value, &mut index).map(|bytes| bytes.to_vec());
        }
        if !skip(value, &mut index, wire) {
            break;
        }
    }
    None
}
