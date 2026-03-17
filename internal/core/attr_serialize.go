package core

import (
	"encoding/binary"
	"fmt"
	"math"
	"unsafe"
)

const serializeDefaultSize = 256
const maxKeyLimit = 16 * 1024 * 1024

// AppendSerialized serialize attr appending data to the src.
func AppendSerialized(src []byte, attr Attr) []byte {
	kind := attr.kind & 0xFF

	if kind != valueKindStringer {
		src = append(src, byte(kind))
	} else {
		src = append(src, byte(ValueKindString))
	}

	switch attr.kind {
	case ValueKindJustContextNode, ValueKindJustContextInheritedNode, ValueKindPhantomContextNode:
		return src
	}

	// Save a key.
	knownKey := attr.kind >> 8
	if knownKey == 0 {
		// String key.
		key := attr.Key
		if len(key) > maxKeyLimit {
			key = key[:maxKeyLimit]
		}
		src = binary.AppendUvarint(src, uint64(len(key)))
		src = append(src, key...)
	} else {
		// Known registered key.
		src = append(src, 0)
		src = binary.AppendUvarint(src, uint64(knownKey))
	}

	// Append core spec. Will not write anything if this is an unsupported spec.
	switch kind {
	case ValueKindLocationNode:
		src = binary.AppendUvarint(src, attr.Value.num)
	case ValueKindBool, ValueKindInt8, ValueKindUint8:
		src = append(src, byte(attr.Value.num))
	case
		ValueKindInt, ValueKindInt64,
		ValueKindUint, ValueKindUint64,
		ValueKindFloat64,
		ValueKindTime, ValueKindDuration:
		src = binary.LittleEndian.AppendUint64(src, attr.Value.num)
	case ValueKindInt16, ValueKindUint16:
		src = binary.LittleEndian.AppendUint16(src, uint16(attr.Value.num))
	case ValueKindInt32, ValueKindUint32, ValueKindFloat32:
		src = binary.LittleEndian.AppendUint32(src, uint32(attr.Value.num))
	case ValueKindString:
		src = binary.AppendUvarint(src, attr.Value.num)
		v := uintptr(attr.Value.ext)
		src = append(src, unsafe.Slice((*byte)(unsafe.Pointer(v)), attr.Value.num)...)
	case valueKindStringer:
		stg := *(*fmt.Stringer)(unsafe.Pointer(&attr.Value))
		txt := stg.String()
		src = binary.AppendUvarint(src, uint64(len(txt)))
		src = append(src, txt...)
	case ValueKindBytes:
		src = binary.AppendUvarint(src, attr.Value.num)
		v := uintptr(attr.Value.ext)
		src = append(src, unsafe.Slice((*byte)(unsafe.Pointer(v)), attr.Value.num)...)
	case ValueKindErrorRaw:
		err := *(*error)(unsafe.Pointer(&attr.Value))
		txt := err.Error()
		src = binary.AppendUvarint(src, uint64(len(txt)))
		src = append(src, txt...)
	case ValueKindError:
		errPtr := (*Error)(unsafe.Pointer(uintptr(attr.Value.ext)))
		src = binary.AppendUvarint(src, uint64(len(errPtr.payload)))
		src = append(src, errPtr.payload...)
	case ValueKindErrorEmbed:
		errPtr := (*Error)(unsafe.Pointer(uintptr(attr.Value.ext)))
		src = binary.AppendUvarint(src, uint64(len(errPtr.text)))
		src = append(src, errPtr.text...)
		src = binary.AppendUvarint(src, uint64(len(errPtr.payload)))
		src = append(src, errPtr.payload...)
	case ValueKindSliceBool, ValueKindSliceInt8, ValueKindSliceUint8:
		src = binary.AppendUvarint(src, attr.Value.num)
		v := unsafe.Slice((*byte)(unsafe.Pointer(uintptr(attr.Value.ext))), attr.Value.num)
		src = append(src, v...)
	case ValueKindSliceInt, ValueKindSliceInt64, ValueKindSliceUint, ValueKindSliceUint64:
		src = binary.AppendUvarint(src, attr.Value.num)
		v := unsafe.Slice((*uint64)(unsafe.Pointer(uintptr(attr.Value.ext))), attr.Value.num)
		for _, vv := range v {
			src = binary.LittleEndian.AppendUint64(src, vv)
		}
	case ValueKindSliceInt16, ValueKindSliceUint16:
		src = binary.AppendUvarint(src, attr.Value.num)
		v := unsafe.Slice((*uint16)(unsafe.Pointer(uintptr(attr.Value.ext))), attr.Value.num)
		for _, vv := range v {
			src = binary.LittleEndian.AppendUint16(src, vv)
		}
	case ValueKindSliceInt32, ValueKindSliceUint32:
		src = binary.AppendUvarint(src, attr.Value.num)
		v := unsafe.Slice((*uint32)(unsafe.Pointer(uintptr(attr.Value.ext))), attr.Value.num)
		for _, vv := range v {
			src = binary.LittleEndian.AppendUint32(src, vv)
		}
	case ValueKindSliceFloat32:
		src = binary.AppendUvarint(src, attr.Value.num)
		v := unsafe.Slice((*float32)(unsafe.Pointer(uintptr(attr.Value.ext))), attr.Value.num)
		for _, vv := range v {
			src = binary.LittleEndian.AppendUint32(src, math.Float32bits(vv))
		}
	case ValueKindSliceFloat64:
		src = binary.AppendUvarint(src, attr.Value.num)
		v := unsafe.Slice((*float64)(unsafe.Pointer(uintptr(attr.Value.ext))), attr.Value.num)
		for _, vv := range v {
			src = binary.LittleEndian.AppendUint64(src, math.Float64bits(vv))
		}
	case ValueKindSliceString:
		src = binary.AppendUvarint(src, attr.Value.num)
		v := unsafe.Slice((*string)(unsafe.Pointer(uintptr(attr.Value.ext))), attr.Value.num)
		for _, vv := range v {
			src = binary.AppendUvarint(src, uint64(len(vv)))
			src = append(src, vv...)
		}
	case ValueKindGroup:
		src = binary.AppendUvarint(src, attr.Value.num)
		v := unsafe.Slice((*Attr)(unsafe.Pointer(uintptr(attr.Value.ext))), attr.Value.num)
		for _, vv := range v {
			src = AppendSerialized(src, vv)
		}
	}

	return src
}
