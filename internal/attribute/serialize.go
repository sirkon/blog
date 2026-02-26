package attribute

import (
	"encoding/binary"
)

// AppendSerialized serialize attr appending data to the src.
func AppendSerialized(src []byte, attr Attr) []byte {
	// Кладем ключ.
	knownKey := attr.kind >> 8
	if knownKey == 0 {
		// Строковой ключ.
		src = binary.AppendUvarint(src, uint64(len(attr.Key)))
		src = append(src, attr.Key...)
	} else {
		// Известный ключ.
		src = append(src, 0)
		src = binary.AppendUvarint(src, uint64(knownKey))
	}

	switch attr.kind & 0xff {
	case ValueKindBool:
	case ValueKindInt:
	case ValueKindInt8:
	case ValueKindInt16:
	case ValueKindInt32:
	case ValueKindInt64:
	case ValueKindUint:
	case ValueKindUint8:
	case ValueKindUint16:
	case ValueKindUint32:
	case ValueKindUint64:
	case ValueKindFloat32:
	case ValueKindFloat64:
	case ValueKindString:
	case ValueKindBytes:
	case ValueKindErrorRaw:
	case ValueKindError:
	case ValueKindSerializer:
	case ValueKindSliceBool:
	case ValueKindSliceInt:
	case ValueKindSliceInt8:
	case ValueKindSliceInt16:
	case ValueKindSliceInt32:
	case ValueKindSliceInt64:
	case ValueKindSliceUint:
	case ValueKindSliceUint8:
	case ValueKindSliceUint16:
	case ValueKindSliceUint32:
	case ValueKindSliceUint64:
	case ValueKindSliceFloat32:
	case ValueKindSliceFloat64:
	case ValueKindSliceString:
	}
}
