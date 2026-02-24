package blog

import (
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
	kind  valueKind
}

// Bool returns an [Attr] for boolean value.
func Bool(key string, value bool) Attr {
	var v uint64
	if value {
		v = 1
	}
	return Attr{
		Key: key,
		Value: Value{
			num: v,
		},
		kind: valueKindBool,
	}
}

// Time returns an [Attr] for [time.Time].
func Time(key string, value time.Time) Attr {
	return Attr{
		Key: key,
		Value: Value{
			num: uint64(value.UnixNano()),
		},
		kind: valueKindTime,
	}
}

// Duration returns an [Attr] for [time.Duration].
func Duration(key string, value time.Duration) Attr {
	return Attr{
		Key: key,
		Value: Value{
			num: uint64(value),
		},
		kind: valueKindDuration,
	}
}

// Int returns an [Attr] for int value.
func Int(key string, value int) Attr {
	return Attr{
		Key: key,
		Value: Value{
			num: uint64(value),
		},
		kind: valueKindInt,
	}
}

// Int8 returns an [Attr] for int8 value.
func Int8(key string, value int8) Attr {
	return Attr{
		Key: key,
		Value: Value{
			num: uint64(value),
		},
		kind: valueKindInt8,
	}
}

// Int16 returns an [Attr] for int16 value.
func Int16(key string, value int16) Attr {
	return Attr{
		Key: key,
		Value: Value{
			num: uint64(value),
		},
		kind: valueKindInt16,
	}
}

// Int32 returns an [Attr] for int32 value.
func Int32(key string, value int32) Attr {
	return Attr{
		Key: key,
		Value: Value{
			num: uint64(value),
		},
		kind: valueKindInt32,
	}
}

// Int64 returns an [Attr] for int64 value.
func Int64(key string, value int64) Attr {
	return Attr{
		Key: key,
		Value: Value{
			num: uint64(value),
		},
		kind: valueKindInt64,
	}
}

// Uint returns an [Attr] for uint value.
func Uint(key string, value uint) Attr {
	return Attr{
		Key: key,
		Value: Value{
			num: uint64(value),
		},
		kind: valueKindUint,
	}
}

// Uint8 returns an [Attr] for uint8 value.
func Uint8(key string, value uint8) Attr {
	return Attr{
		Key: key,
		Value: Value{
			num: uint64(value),
		},
		kind: valueKindUint8,
	}
}

// Uint16 returns an [Attr] for uint16 value.
func Uint16(key string, value uint16) Attr {
	return Attr{
		Key: key,
		Value: Value{
			num: uint64(value),
		},
		kind: valueKindUint16,
	}
}

// Uint32 returns an [Attr] for uint32 value.
func Uint32(key string, value uint32) Attr {
	return Attr{
		Key: key,
		Value: Value{
			num: uint64(value),
		},
		kind: valueKindUint32,
	}
}

// Uint64 returns an [Attr] for uint64 value.
func Uint64(key string, value uint64) Attr {
	return Attr{
		Key: key,
		Value: Value{
			num: value,
		},
		kind: valueKindUint64,
	}
}

// Flt32 returns an [Attr] for float32 value.
func Flt32(key string, value float32) Attr {
	return Attr{
		Key: key,
		Value: Value{
			num: uint64(math.Float32bits(value)),
		},
		kind: valueKindFloat32,
	}
}

// Flt64 returns an [Attr] for float64 value.
func Flt64(key string, value float64) Attr {
	return Attr{
		Key: key,
		Value: Value{
			num: math.Float64bits(value),
		},
		kind: valueKindFloat64,
	}
}

// Str returns an [Attr] for string value.
func Str(key string, value string) Attr {
	return Attr{
		Key: key,
		Value: Value{
			num: uint64(len(value)),
			srl: (*stringPtr)(unsafe.Pointer(unsafe.StringData(value))),
		},
		kind: valueKindString,
	}
}

// Stg returns an [Attr] for [fmt.Stringer] value packed as just a string.
func Stg(key string, value fmt.Stringer) Attr {
	val := value.String()
	strPtr := (*stringPtr)(unsafe.Pointer(unsafe.StringData(val)))
	return Attr{
		Key: key,
		Value: Value{
			num: uint64(len(val)),
			srl: strPtr,
		},
		kind: valueKindString,
	}
}

// Bytes returns an [Attr] for []byte value.
func Bytes(key string, value []byte) Attr {
	var kind valueKind
	var ptr Serializer
	if isPrintableStringWithSpaces(value) {
		kind = valueKindString
		ptr = (*stringPtr)(unsafe.Pointer(unsafe.SliceData(value)))
	} else {
		kind = valueKindBytes
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

// Error returns an [Attr] for error value packed as just a string.
// TODO implement dedicated [beer.Error] support.
func Error(key string, err error) Attr {
	// Here is the place for [beer.Error] dispatch.
	// It may cause an additional alloc in case there's a [beer.Error] in the chain
	// yet it is just a generic [error] at the surface level.

	// End of dispatch.

	val := err.Error()
	return Attr{
		Key: key,
		Value: Value{
			num: uint64(len(val)),
			srl: (*stringPtr)(unsafe.Pointer(unsafe.StringData(val))),
		},
		kind: valueKindErrorRaw,
	}
}

// Err shortcut for Error("err", err).
func Err(err error) Attr {
	return Error("err", err)
}

// Bools returns an [Attr] for []bool value.
func Bools(key string, value []bool) Attr {
	return Attr{
		Key: key,
		Value: Value{
			num: uint64(len(value)),
			srl: (*boolSlicePtr)(unsafe.Pointer(unsafe.SliceData(value))),
		},
		kind: valueKindSliceBool,
	}
}

// Ints returns an [Attr] for []int value.
func Ints(key string, value []int8) Attr {
	return Attr{
		Key: key,
		Value: Value{
			num: uint64(len(value)),
			srl: (*intSlicePtr)(unsafe.Pointer(unsafe.SliceData(value))),
		},
		kind: valueKindSliceInt8,
	}
}

// Int8s returns an [Attr] for []int8 value.
func Int8s(key string, value []int8) Attr {
	return Attr{
		Key: key,
		Value: Value{
			num: uint64(len(value)),
			srl: (*int8SlicePtr)(unsafe.Pointer(unsafe.SliceData(value))),
		},
		kind: valueKindSliceInt8,
	}
}

// Int16s returns an [Attr] for []int16 value.
func Int16s(key string, value []int16) Attr {
	return Attr{
		Key: key,
		Value: Value{
			num: uint64(len(value)),
			srl: (*int16SlicePtr)(unsafe.Pointer(unsafe.SliceData(value))),
		},
		kind: valueKindSliceInt16,
	}
}

// Int32s returns an [Attr] for []int32 value.
func Int32s(key string, value []int32) Attr {
	return Attr{
		Key: key,
		Value: Value{
			num: uint64(len(value)),
			srl: (*int32SlicePtr)(unsafe.Pointer(unsafe.SliceData(value))),
		},
		kind: valueKindSliceInt32,
	}
}

// Int64s returns an [Attr] for []int64 value.
func Int64s(key string, value []int64) Attr {
	return Attr{
		Key: key,
		Value: Value{
			num: uint64(len(value)),
			srl: (*int64SlicePtr)(unsafe.Pointer(unsafe.SliceData(value))),
		},
		kind: valueKindSliceInt64,
	}
}

// Uints returns an [Attr] for []uint value.
func Uints(key string, value []uint8) Attr {
	return Attr{
		Key: key,
		Value: Value{
			num: uint64(len(value)),
			srl: (*uintSlicePtr)(unsafe.Pointer(unsafe.SliceData(value))),
		},
		kind: valueKindSliceUint8,
	}
}

// Uint8s returns an [Attr] for []uint8 value.
func Uint8s(key string, value []uint8) Attr {
	return Attr{
		Key: key,
		Value: Value{
			num: uint64(len(value)),
			srl: (*uint8SlicePtr)(unsafe.Pointer(unsafe.SliceData(value))),
		},
		kind: valueKindSliceUint8,
	}
}

// Uint16s returns an [Attr] for []uint16 value.
func Uint16s(key string, value []uint16) Attr {
	return Attr{
		Key: key,
		Value: Value{
			num: uint64(len(value)),
			srl: (*uint16SlicePtr)(unsafe.Pointer(unsafe.SliceData(value))),
		},
		kind: valueKindSliceUint16,
	}
}

// Uint32s returns an [Attr] for []uint32 value.
func Uint32s(key string, value []uint32) Attr {
	return Attr{
		Key: key,
		Value: Value{
			num: uint64(len(value)),
			srl: (*uint32SlicePtr)(unsafe.Pointer(unsafe.SliceData(value))),
		},
		kind: valueKindSliceUint32,
	}
}

// Uint64s returns an [Attr] for []uint64 value.
func Uint64s(key string, value []uint64) Attr {
	return Attr{
		Key: key,
		Value: Value{
			num: uint64(len(value)),
			srl: (*uint64SlicePtr)(unsafe.Pointer(unsafe.SliceData(value))),
		},
		kind: valueKindSliceUint64,
	}
}

// Flt32s returns an [Attr] for []float32 value.
func Flt32s(key string, value []float32) Attr {
	return Attr{
		Key: key,
		Value: Value{
			num: uint64(len(value)),
			srl: (*float32SlicePtr)(unsafe.Pointer(unsafe.SliceData(value))),
		},
		kind: valueKindSliceFloat32,
	}
}

// Flt64s returns an [Attr] for []float64 value.
func Flt64s(key string, value []float64) Attr {
	return Attr{
		Key: key,
		Value: Value{
			num: uint64(len(value)),
			srl: (*float64SlicePtr)(unsafe.Pointer(unsafe.SliceData(value))),
		},
		kind: valueKindSliceFloat64,
	}
}

// Strs returns an [Attr] for []string value.
func Strs(key string, value []string) Attr {
	return Attr{
		Key: key,
		Value: Value{
			num: uint64(len(value)),
			srl: (*stringSlicePtr)(unsafe.Pointer(unsafe.SliceData(value))),
		},
		kind: valueKindSliceString,
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
