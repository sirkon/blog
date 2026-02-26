package attribute

import (
	"encoding/binary"
	"math"
	"unsafe"
)

const serializeDefaultSize = 256

// AppendSerialized serialize attr appending data to the src.
func AppendSerialized(src []byte, attr Attr) []byte {
	// Кладем ключ.
	knownKey := attr.kind >> 8
	if knownKey == 0 {
		// String key.
		src = binary.AppendUvarint(src, uint64(len(attr.Key)))
		src = append(src, attr.Key...)
	} else {
		// Known registered key.
		src = append(src, 0)
		src = binary.AppendUvarint(src, uint64(knownKey))
	}

	kind := attr.kind & 0xff
	src = append(src, byte(kind))

	// Append attribute value. Will not write anything if this is an unsupported value.
	switch kind {
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
	case ValueKindString, ValueKindErrorRaw:
		src = binary.AppendUvarint(src, attr.Value.num)
		v := attr.Value.srl.(*stringPtr)
		src = append(src, unsafe.Slice((*byte)(unsafe.Pointer(v)), attr.Value.num)...)
	case ValueKindBytes:
		src = binary.AppendUvarint(src, attr.Value.num)
		v := attr.Value.srl.(*bytesPtr)
		src = append(src, unsafe.Slice((*byte)(unsafe.Pointer(v)), attr.Value.num)...)
	case ValueKindError:
		// TODO implement this once beer is ready.
	case ValueKindSerializer:
		data := attr.Value.srl.Serialize(make([]byte, 0, serializeDefaultSize))
		src = binary.AppendUvarint(src, uint64(len(data)))
		src = append(src, data...)
	case ValueKindSliceBool:
		src = binary.AppendUvarint(src, attr.Value.num)
		v := unsafe.Slice((*byte)(unsafe.Pointer(attr.Value.srl.(*boolSlicePtr))), attr.Value.num)
		src = append(src, v...)
	case ValueKindSliceInt:
		src = binary.AppendUvarint(src, attr.Value.num)
		v := unsafe.Slice((*int)(unsafe.Pointer(attr.Value.srl.(*intSlicePtr))), attr.Value.num)
		for _, vv := range v {
			src = binary.LittleEndian.AppendUint64(src, uint64(vv))
		}
	case ValueKindSliceInt8:
		src = binary.AppendUvarint(src, attr.Value.num)
		v := unsafe.Slice((*byte)(unsafe.Pointer(attr.Value.srl.(*int8SlicePtr))), attr.Value.num)
		src = append(src, v...)
	case ValueKindSliceInt16:
		src = binary.AppendUvarint(src, attr.Value.num)
		v := unsafe.Slice((*int16)(unsafe.Pointer(attr.Value.srl.(*int16SlicePtr))), attr.Value.num)
		for _, vv := range v {
			src = binary.LittleEndian.AppendUint16(src, uint16(vv))
		}
	case ValueKindSliceInt32:
		src = binary.AppendUvarint(src, attr.Value.num)
		v := unsafe.Slice((*int32)(unsafe.Pointer(attr.Value.srl.(*int32SlicePtr))), attr.Value.num)
		for _, vv := range v {
			src = binary.LittleEndian.AppendUint32(src, uint32(vv))
		}
	case ValueKindSliceInt64:
		src = binary.AppendUvarint(src, attr.Value.num)
		v := unsafe.Slice((*int64)(unsafe.Pointer(attr.Value.srl.(*int64SlicePtr))), attr.Value.num)
		for _, vv := range v {
			src = binary.LittleEndian.AppendUint64(src, uint64(vv))
		}
	case ValueKindSliceUint:
		src = binary.AppendUvarint(src, attr.Value.num)
		v := unsafe.Slice((*uint)(unsafe.Pointer(attr.Value.srl.(*uintSlicePtr))), attr.Value.num)
		for _, vv := range v {
			src = binary.LittleEndian.AppendUint64(src, uint64(vv))
		}
	case ValueKindSliceUint8:
		src = binary.AppendUvarint(src, attr.Value.num)
		v := unsafe.Slice((*byte)(unsafe.Pointer(attr.Value.srl.(*uint8SlicePtr))), attr.Value.num)
		src = append(src, v...)
	case ValueKindSliceUint16:
		src = binary.AppendUvarint(src, attr.Value.num)
		v := unsafe.Slice((*uint16)(unsafe.Pointer(attr.Value.srl.(*uint16SlicePtr))), attr.Value.num)
		for _, vv := range v {
			src = binary.LittleEndian.AppendUint16(src, vv)
		}
	case ValueKindSliceUint32:
		src = binary.AppendUvarint(src, attr.Value.num)
		v := unsafe.Slice((*uint32)(unsafe.Pointer(attr.Value.srl.(*uint32SlicePtr))), attr.Value.num)
		for _, vv := range v {
			src = binary.LittleEndian.AppendUint32(src, vv)
		}
	case ValueKindSliceUint64:
		src = binary.AppendUvarint(src, attr.Value.num)
		v := unsafe.Slice((*uint64)(unsafe.Pointer(attr.Value.srl.(*uint64SlicePtr))), attr.Value.num)
		for _, vv := range v {
			src = binary.LittleEndian.AppendUint64(src, vv)
		}
	case ValueKindSliceFloat32:
		src = binary.AppendUvarint(src, attr.Value.num)
		v := unsafe.Slice((*float32)(unsafe.Pointer(attr.Value.srl.(*float32SlicePtr))), attr.Value.num)
		for _, vv := range v {
			src = binary.LittleEndian.AppendUint32(src, math.Float32bits(vv))
		}
	case ValueKindSliceFloat64:
		src = binary.AppendUvarint(src, attr.Value.num)
		v := unsafe.Slice((*float64)(unsafe.Pointer(attr.Value.srl.(*float64SlicePtr))), attr.Value.num)
		for _, vv := range v {
			src = binary.LittleEndian.AppendUint64(src, math.Float64bits(vv))
		}
	case ValueKindSliceString:
		src = binary.AppendUvarint(src, attr.Value.num)
		v := unsafe.Slice((*string)(unsafe.Pointer(attr.Value.srl.(*stringSlicePtr))), attr.Value.num)
		for _, vv := range v {
			src = binary.AppendUvarint(src, uint64(len(vv)))
			src = append(src, vv...)
		}
	case ValueKindGroup:
		src = binary.AppendUvarint(src, attr.Value.num)
		v := unsafe.Slice((*Attr)(unsafe.Pointer(attr.Value.srl.(*groupPtr))), attr.Value.num)
		for _, vv := range v {
			src = AppendSerialized(src, vv)
		}
	}

	return src
}
