package core

import (
	"errors"
	"fmt"
	"math"
	"time"
	"unicode"
	"unicode/utf8"
	"unsafe"
)

// Attr a key-value pair for logging context.
type Attr struct {
	Key   string
	Value Value
	kind  ValueKind
}

// Kind returns value of kind.
func (a Attr) Kind() ValueKind { return a.kind }

// Bool returns an [Attr] for boolean value.
func Bool(key string, value bool) Attr {
	_ = key[0]
	var v uint64
	if value {
		v = 1
	}
	return Attr{
		Key: key,
		Value: Value{
			num: v,
		},
		kind: ValueKindBool,
	}
}

// Time returns an [Attr] for [time.Time].
func Time(key string, value time.Time) Attr {
	_ = key[0]
	return Attr{
		Key: key,
		Value: Value{
			num: uint64(value.UnixNano()),
		},
		kind: ValueKindTime,
	}
}

// Duration returns an [Attr] for [time.Duration].
func Duration(key string, value time.Duration) Attr {
	_ = key[0]
	return Attr{
		Key: key,
		Value: Value{
			num: uint64(value),
		},
		kind: ValueKindDuration,
	}
}

// Int returns an [Attr] for int value.
func Int(key string, value int) Attr {
	_ = key[0]
	return Attr{
		Key: key,
		Value: Value{
			num: uint64(value),
		},
		kind: ValueKindInt,
	}
}

// Int8 returns an [Attr] for int8 value.
func Int8(key string, value int8) Attr {
	_ = key[0]
	return Attr{
		Key: key,
		Value: Value{
			num: uint64(value),
		},
		kind: ValueKindInt8,
	}
}

// Int16 returns an [Attr] for int16 value.
func Int16(key string, value int16) Attr {
	_ = key[0]
	return Attr{
		Key: key,
		Value: Value{
			num: uint64(value),
		},
		kind: ValueKindInt16,
	}
}

// Int32 returns an [Attr] for int32 value.
func Int32(key string, value int32) Attr {
	_ = key[0]
	return Attr{
		Key: key,
		Value: Value{
			num: uint64(value),
		},
		kind: ValueKindInt32,
	}
}

// Int64 returns an [Attr] for int64 value.
func Int64(key string, value int64) Attr {
	_ = key[0]
	return Attr{
		Key: key,
		Value: Value{
			num: uint64(value),
		},
		kind: ValueKindInt64,
	}
}

// Uint returns an [Attr] for uint value.
func Uint(key string, value uint) Attr {
	_ = key[0]
	return Attr{
		Key: key,
		Value: Value{
			num: uint64(value),
		},
		kind: ValueKindUint,
	}
}

// Uint8 returns an [Attr] for uint8 value.
func Uint8(key string, value uint8) Attr {
	_ = key[0]
	return Attr{
		Key: key,
		Value: Value{
			num: uint64(value),
		},
		kind: ValueKindUint8,
	}
}

// Uint16 returns an [Attr] for uint16 value.
func Uint16(key string, value uint16) Attr {
	_ = key[0]
	return Attr{
		Key: key,
		Value: Value{
			num: uint64(value),
		},
		kind: ValueKindUint16,
	}
}

// Uint32 returns an [Attr] for uint32 value.
func Uint32(key string, value uint32) Attr {
	_ = key[0]
	return Attr{
		Key: key,
		Value: Value{
			num: uint64(value),
		},
		kind: ValueKindUint32,
	}
}

// Uint64 returns an [Attr] for uint64 value.
func Uint64(key string, value uint64) Attr {
	_ = key[0]
	return Attr{
		Key: key,
		Value: Value{
			num: value,
		},
		kind: ValueKindUint64,
	}
}

// Flt32 returns an [Attr] for float32 value.
func Flt32(key string, value float32) Attr {
	_ = key[0]
	return Attr{
		Key: key,
		Value: Value{
			num: uint64(math.Float32bits(value)),
		},
		kind: ValueKindFloat32,
	}
}

// Flt64 returns an [Attr] for float64 value.
func Flt64(key string, value float64) Attr {
	_ = key[0]
	return Attr{
		Key: key,
		Value: Value{
			num: math.Float64bits(value),
		},
		kind: ValueKindFloat64,
	}
}

// Str returns an [Attr] for string value.
func Str(key string, value string) Attr {
	_ = key[0]
	return Attr{
		Key: key,
		Value: Value{
			num: uint64(len(value)),
			srl: (*stringPtr)(unsafe.Pointer(unsafe.StringData(value))),
		},
		kind: ValueKindString,
	}
}

// Stg returns an [Attr] for [fmt.Stringer] value packed as just a string.
func Stg(key string, value fmt.Stringer) Attr {
	_ = key[0]
	val := value.String()
	strPtr := (*stringPtr)(unsafe.Pointer(unsafe.StringData(val)))
	return Attr{
		Key: key,
		Value: Value{
			num: uint64(len(val)),
			srl: strPtr,
		},
		kind: ValueKindString,
	}
}

// Bytes returns an [Attr] for []byte value.
func Bytes(key string, value []byte) Attr {
	_ = key[0]
	var kind ValueKind
	var ptr Serializer
	if isPrintableStringWithSpaces(value) {
		kind = ValueKindString
		ptr = (*stringPtr)(unsafe.Pointer(unsafe.SliceData(value)))
	} else {
		kind = ValueKindBytes
		ptr = (*bytesPtr)(unsafe.Pointer(unsafe.SliceData(value)))
	}

	return Attr{
		Key: key,
		Value: Value{
			num: uint64(len(value)),
			srl: ptr,
		},
		kind: kind,
	}
}

// ErrorAttr returns an [Attr] for error value packed as just a string.
func ErrorAttr(key string, err error) Attr {
	_ = key[0]
	e, ok := err.(*Error)
	if !ok {
		e, ok = errors.AsType[*Error](err)
		if ok {
			e = &Error{
				payload:    e.payload,
				wrap:       e.wrap,
				sufficient: false,
			}
		}
	}
	if ok {
		// CAUTION: we typically doesn't have enough info in the payload
		// to reconstruct a message just with payload alone. Foreign
		// errors are black boxes, and we need to compute the whole message
		// explicitly in order not to lose precise text. But there's a corner
		// where we still can optimize: if a foreign error is on the very tail.
		// We can embed its text in the payload then.
		kind := ValueKindError
		if !e.sufficient {
			e.text = err.Error()
			kind = ValueKindErrorEmbed
		}

		return Attr{
			Key: key,
			Value: Value{
				srl: (*errorPtr)(unsafe.Pointer(e)),
			},
			kind: kind,
		}
	}

	val := err.Error()
	return Attr{
		Key: key,
		Value: Value{
			num: uint64(len(val)),
			srl: (*stringPtr)(unsafe.Pointer(unsafe.StringData(val))),
		},
		kind: ValueKindErrorRaw,
	}
}

// Err shortcut for Error("err", err).
// Эта функция не имеет параметра key, поэтому проверка не добавляется
func Err(err error) Attr {
	return ErrorAttr("err", err)
}

// Bools returns an [Attr] for []bool value.
func Bools(key string, value []bool) Attr {
	_ = key[0]
	return Attr{
		Key: key,
		Value: Value{
			num: uint64(len(value)),
			srl: (*boolSlicePtr)(unsafe.Pointer(unsafe.SliceData(value))),
		},
		kind: ValueKindSliceBool,
	}
}

// Ints returns an [Attr] for []int value.
func Ints(key string, value []int) Attr {
	_ = key[0]
	return Attr{
		Key: key,
		Value: Value{
			num: uint64(len(value)),
			srl: (*intSlicePtr)(unsafe.Pointer(unsafe.SliceData(value))),
		},
		kind: ValueKindSliceInt8,
	}
}

// Int8s returns an [Attr] for []int8 value.
func Int8s(key string, value []int8) Attr {
	_ = key[0]
	return Attr{
		Key: key,
		Value: Value{
			num: uint64(len(value)),
			srl: (*int8SlicePtr)(unsafe.Pointer(unsafe.SliceData(value))),
		},
		kind: ValueKindSliceInt8,
	}
}

// Int16s returns an [Attr] for []int16 value.
func Int16s(key string, value []int16) Attr {
	_ = key[0]
	return Attr{
		Key: key,
		Value: Value{
			num: uint64(len(value)),
			srl: (*int16SlicePtr)(unsafe.Pointer(unsafe.SliceData(value))),
		},
		kind: ValueKindSliceInt16,
	}
}

// Int32s returns an [Attr] for []int32 value.
func Int32s(key string, value []int32) Attr {
	_ = key[0]
	return Attr{
		Key: key,
		Value: Value{
			num: uint64(len(value)),
			srl: (*int32SlicePtr)(unsafe.Pointer(unsafe.SliceData(value))),
		},
		kind: ValueKindSliceInt32,
	}
}

// Int64s returns an [Attr] for []int64 value.
func Int64s(key string, value []int64) Attr {
	_ = key[0]
	return Attr{
		Key: key,
		Value: Value{
			num: uint64(len(value)),
			srl: (*int64SlicePtr)(unsafe.Pointer(unsafe.SliceData(value))),
		},
		kind: ValueKindSliceInt64,
	}
}

// Uints returns an [Attr] for []uint value.
func Uints(key string, value []uint) Attr {
	_ = key[0]
	return Attr{
		Key: key,
		Value: Value{
			num: uint64(len(value)),
			srl: (*uintSlicePtr)(unsafe.Pointer(unsafe.SliceData(value))),
		},
		kind: ValueKindSliceUint,
	}
}

// Uint8s returns an [Attr] for []uint8 value.
func Uint8s(key string, value []uint8) Attr {
	_ = key[0]
	return Attr{
		Key: key,
		Value: Value{
			num: uint64(len(value)),
			srl: (*uint8SlicePtr)(unsafe.Pointer(unsafe.SliceData(value))),
		},
		kind: ValueKindSliceUint8,
	}
}

// Uint16s returns an [Attr] for []uint16 value.
func Uint16s(key string, value []uint16) Attr {
	_ = key[0]
	return Attr{
		Key: key,
		Value: Value{
			num: uint64(len(value)),
			srl: (*uint16SlicePtr)(unsafe.Pointer(unsafe.SliceData(value))),
		},
		kind: ValueKindSliceUint16,
	}
}

// Uint32s returns an [Attr] for []uint32 value.
func Uint32s(key string, value []uint32) Attr {
	_ = key[0]
	return Attr{
		Key: key,
		Value: Value{
			num: uint64(len(value)),
			srl: (*uint32SlicePtr)(unsafe.Pointer(unsafe.SliceData(value))),
		},
		kind: ValueKindSliceUint32,
	}
}

// Uint64s returns an [Attr] for []uint64 value.
func Uint64s(key string, value []uint64) Attr {
	_ = key[0]
	return Attr{
		Key: key,
		Value: Value{
			num: uint64(len(value)),
			srl: (*uint64SlicePtr)(unsafe.Pointer(unsafe.SliceData(value))),
		},
		kind: ValueKindSliceUint64,
	}
}

// Flt32s returns an [Attr] for []float32 value.
func Flt32s(key string, value []float32) Attr {
	_ = key[0]
	return Attr{
		Key: key,
		Value: Value{
			num: uint64(len(value)),
			srl: (*float32SlicePtr)(unsafe.Pointer(unsafe.SliceData(value))),
		},
		kind: ValueKindSliceFloat32,
	}
}

// Flt64s returns an [Attr] for []float64 value.
func Flt64s(key string, value []float64) Attr {
	_ = key[0]
	return Attr{
		Key: key,
		Value: Value{
			num: uint64(len(value)),
			srl: (*float64SlicePtr)(unsafe.Pointer(unsafe.SliceData(value))),
		},
		kind: ValueKindSliceFloat64,
	}
}

// Strs returns an [Attr] for []string value.
func Strs(key string, value []string) Attr {
	_ = key[0]
	return Attr{
		Key: key,
		Value: Value{
			num: uint64(len(value)),
			srl: (*stringSlicePtr)(unsafe.Pointer(unsafe.SliceData(value))),
		},
		kind: ValueKindSliceString,
	}
}

// Group returns an [Attr] for []Attr value.
func Group(key string, value ...Attr) Attr {
	_ = key[0]
	return Attr{
		Key: key,
		Value: Value{
			num: uint64(len(value)),
			srl: (*groupPtr)(unsafe.Pointer(unsafe.SliceData(value))),
		},
		kind: ValueKindGroup,
	}
}

// Obj returns an [Attr] for Serializer value.
func Obj(key string, value Serializer) Attr {
	_ = key[0]
	return Attr{
		Key: key,
		Value: Value{
			srl: value,
		},
		kind: ValueKindSerializer,
	}
}

func isPrintableStringWithSpaces(b []byte) bool {
	for len(b) > 0 {
		r, size := utf8.DecodeRune(b)
		if r == utf8.RuneError || (!unicode.IsPrint(r) && !unicode.IsSpace(r)) {
			return false
		}
		b = b[size:]
	}
	return true
}
