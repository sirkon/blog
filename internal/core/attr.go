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

// Attr a key-spec pair for logging context.
type Attr struct {
	Key   string
	Value attrValue
	kind  ValueKind
}

// attrValue that is meant to keep any numeric values, pointers and strings via
// unsafe transformations. No GC care needed because the value is meant
// to be serialized into []byte BEFORE the value it references will disappear.
type attrValue struct {
	num uint64
	ext uint64
}

// Kind returns spec of kind.
func (a Attr) Kind() ValueKind { return a.kind }

// Bool returns an [Attr] for boolean spec.
func Bool(key string, value bool) Attr {
	_ = key[0]
	var v uint64
	if value {
		v = 1
	}
	return Attr{
		Key: key,
		Value: attrValue{
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
		Value: attrValue{
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
		Value: attrValue{
			num: uint64(value),
		},
		kind: ValueKindDuration,
	}
}

// Int returns an [Attr] for int spec.
func Int(key string, value int) Attr {
	_ = key[0]
	return Attr{
		Key: key,
		Value: attrValue{
			num: uint64(value),
		},
		kind: ValueKindInt,
	}
}

// Int8 returns an [Attr] for int8 spec.
func Int8(key string, value int8) Attr {
	_ = key[0]
	return Attr{
		Key: key,
		Value: attrValue{
			num: uint64(value),
		},
		kind: ValueKindInt8,
	}
}

// Int16 returns an [Attr] for int16 spec.
func Int16(key string, value int16) Attr {
	_ = key[0]
	return Attr{
		Key: key,
		Value: attrValue{
			num: uint64(value),
		},
		kind: ValueKindInt16,
	}
}

// Int32 returns an [Attr] for int32 spec.
func Int32(key string, value int32) Attr {
	_ = key[0]
	return Attr{
		Key: key,
		Value: attrValue{
			num: uint64(value),
		},
		kind: ValueKindInt32,
	}
}

// Int64 returns an [Attr] for int64 spec.
func Int64(key string, value int64) Attr {
	_ = key[0]
	return Attr{
		Key: key,
		Value: attrValue{
			num: uint64(value),
		},
		kind: ValueKindInt64,
	}
}

// Uint returns an [Attr] for uint spec.
func Uint(key string, value uint) Attr {
	_ = key[0]
	return Attr{
		Key: key,
		Value: attrValue{
			num: uint64(value),
		},
		kind: ValueKindUint,
	}
}

// Uint8 returns an [Attr] for uint8 spec.
func Uint8(key string, value uint8) Attr {
	_ = key[0]
	return Attr{
		Key: key,
		Value: attrValue{
			num: uint64(value),
		},
		kind: ValueKindUint8,
	}
}

// Uint16 returns an [Attr] for uint16 spec.
func Uint16(key string, value uint16) Attr {
	_ = key[0]
	return Attr{
		Key: key,
		Value: attrValue{
			num: uint64(value),
		},
		kind: ValueKindUint16,
	}
}

// Uint32 returns an [Attr] for uint32 spec.
func Uint32(key string, value uint32) Attr {
	_ = key[0]
	return Attr{
		Key: key,
		Value: attrValue{
			num: uint64(value),
		},
		kind: ValueKindUint32,
	}
}

// Uint64 returns an [Attr] for uint64 spec.
func Uint64(key string, value uint64) Attr {
	_ = key[0]
	return Attr{
		Key: key,
		Value: attrValue{
			num: value,
		},
		kind: ValueKindUint64,
	}
}

// Flt32 returns an [Attr] for float32 spec.
func Flt32(key string, value float32) Attr {
	_ = key[0]
	return Attr{
		Key: key,
		Value: attrValue{
			num: uint64(math.Float32bits(value)),
		},
		kind: ValueKindFloat32,
	}
}

// Flt64 returns an [Attr] for float64 spec.
func Flt64(key string, value float64) Attr {
	_ = key[0]
	return Attr{
		Key: key,
		Value: attrValue{
			num: math.Float64bits(value),
		},
		kind: ValueKindFloat64,
	}
}

// Str returns an [Attr] for string spec.
func Str(key string, value string) Attr {
	_ = key[0]
	return Attr{
		Key: key,
		Value: attrValue{
			num: uint64(len(value)),
			ext: uint64(uintptr(unsafe.Pointer(unsafe.StringData(value)))),
		},
		kind: ValueKindString,
	}
}

// Stg returns an [Attr] for [fmt.Stringer] spec packed as just a string.
func Stg(key string, value fmt.Stringer) Attr {
	_ = key[0]
	return Attr{
		Key:   key,
		Value: *(*attrValue)(unsafe.Pointer(&value)),
		kind:  ValueKindString,
	}
}

// Bytes returns an [Attr] for []byte spec.
func Bytes(key string, value []byte) Attr {
	_ = key[0]
	var kind ValueKind
	if isPrintableStringWithSpaces(value) {
		kind = ValueKindString
	} else {
		kind = ValueKindBytes
	}

	return Attr{
		Key: key,
		Value: attrValue{
			num: uint64(len(value)),
			ext: uint64(uintptr(unsafe.Pointer(unsafe.SliceData(value)))),
		},
		kind: kind,
	}
}

// ErrorAttr returns an [Attr] for error spec packed as just a string.
func ErrorAttr(key string, err error) Attr {
	_ = key[0]
	e, ok := err.(*Error)
	if !ok {
		e, ok = errors.AsType[*Error](err)
		if ok {
			e.sufficient = false
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
			Value: attrValue{
				ext: uint64(uintptr(unsafe.Pointer(e))),
			},
			kind: kind,
		}
	}

	return Attr{
		Key:   key,
		Value: *(*attrValue)(unsafe.Pointer(&err)),
		kind:  ValueKindErrorRaw,
	}
}

// Err shortcut for Error("err", err).
// Эта функция не имеет параметра key, поэтому проверка не добавляется
func Err(err error) Attr {
	return ErrorAttr("err", err)
}

// Bools returns an [Attr] for []bool spec.
func Bools(key string, value []bool) Attr {
	_ = key[0]
	return Attr{
		Key: key,
		Value: attrValue{
			num: uint64(len(value)),
			ext: uint64(uintptr(unsafe.Pointer(unsafe.SliceData(value)))),
		},
		kind: ValueKindSliceBool,
	}
}

// Ints returns an [Attr] for []int spec.
func Ints(key string, value []int) Attr {
	_ = key[0]
	return Attr{
		Key: key,
		Value: attrValue{
			num: uint64(len(value)),
			ext: uint64(uintptr(unsafe.Pointer(unsafe.SliceData(value)))),
		},
		kind: ValueKindSliceInt,
	}
}

// Int8s returns an [Attr] for []int8 spec.
func Int8s(key string, value []int8) Attr {
	_ = key[0]
	return Attr{
		Key: key,
		Value: attrValue{
			num: uint64(len(value)),
			ext: uint64(uintptr(unsafe.Pointer(unsafe.SliceData(value)))),
		},
		kind: ValueKindSliceInt8,
	}
}

// Int16s returns an [Attr] for []int16 spec.
func Int16s(key string, value []int16) Attr {
	_ = key[0]
	return Attr{
		Key: key,
		Value: attrValue{
			num: uint64(len(value)),
			ext: uint64(uintptr(unsafe.Pointer(unsafe.SliceData(value)))),
		},
		kind: ValueKindSliceInt16,
	}
}

// Int32s returns an [Attr] for []int32 spec.
func Int32s(key string, value []int32) Attr {
	_ = key[0]
	return Attr{
		Key: key,
		Value: attrValue{
			num: uint64(len(value)),
			ext: uint64(uintptr(unsafe.Pointer(unsafe.SliceData(value)))),
		},
		kind: ValueKindSliceInt32,
	}
}

// Int64s returns an [Attr] for []int64 spec.
func Int64s(key string, value []int64) Attr {
	_ = key[0]
	return Attr{
		Key: key,
		Value: attrValue{
			num: uint64(len(value)),
			ext: uint64(uintptr(unsafe.Pointer(unsafe.SliceData(value)))),
		},
		kind: ValueKindSliceInt64,
	}
}

// Uints returns an [Attr] for []uint spec.
func Uints(key string, value []uint) Attr {
	_ = key[0]
	return Attr{
		Key: key,
		Value: attrValue{
			num: uint64(len(value)),
			ext: uint64(uintptr(unsafe.Pointer(unsafe.SliceData(value)))),
		},
		kind: ValueKindSliceUint,
	}
}

// Uint8s returns an [Attr] for []uint8 spec.
func Uint8s(key string, value []uint8) Attr {
	_ = key[0]
	return Attr{
		Key: key,
		Value: attrValue{
			num: uint64(len(value)),
			ext: uint64(uintptr(unsafe.Pointer(unsafe.SliceData(value)))),
		},
		kind: ValueKindSliceUint8,
	}
}

// Uint16s returns an [Attr] for []uint16 spec.
func Uint16s(key string, value []uint16) Attr {
	_ = key[0]
	return Attr{
		Key: key,
		Value: attrValue{
			num: uint64(len(value)),
			ext: uint64(uintptr(unsafe.Pointer(unsafe.SliceData(value)))),
		},
		kind: ValueKindSliceUint16,
	}
}

// Uint32s returns an [Attr] for []uint32 spec.
func Uint32s(key string, value []uint32) Attr {
	_ = key[0]
	return Attr{
		Key: key,
		Value: attrValue{
			num: uint64(len(value)),
			ext: uint64(uintptr(unsafe.Pointer(unsafe.SliceData(value)))),
		},
		kind: ValueKindSliceUint32,
	}
}

// Uint64s returns an [Attr] for []uint64 spec.
func Uint64s(key string, value []uint64) Attr {
	_ = key[0]
	return Attr{
		Key: key,
		Value: attrValue{
			num: uint64(len(value)),
			ext: uint64(uintptr(unsafe.Pointer(unsafe.SliceData(value)))),
		},
		kind: ValueKindSliceUint64,
	}
}

// Flt32s returns an [Attr] for []float32 spec.
func Flt32s(key string, value []float32) Attr {
	_ = key[0]
	return Attr{
		Key: key,
		Value: attrValue{
			num: uint64(len(value)),
			ext: uint64(uintptr(unsafe.Pointer(unsafe.SliceData(value)))),
		},
		kind: ValueKindSliceFloat32,
	}
}

// Flt64s returns an [Attr] for []float64 spec.
func Flt64s(key string, value []float64) Attr {
	_ = key[0]
	return Attr{
		Key: key,
		Value: attrValue{
			num: uint64(len(value)),
			ext: uint64(uintptr(unsafe.Pointer(unsafe.SliceData(value)))),
		},
		kind: ValueKindSliceFloat64,
	}
}

// Strs returns an [Attr] for []string spec.
func Strs(key string, value []string) Attr {
	_ = key[0]
	return Attr{
		Key: key,
		Value: attrValue{
			num: uint64(len(value)),
			ext: uint64(uintptr(unsafe.Pointer(unsafe.SliceData(value)))),
		},
		kind: ValueKindSliceString,
	}
}

// Group returns an [Attr] for []Attr spec.
func Group(key string, value ...Attr) Attr {
	_ = key[0]
	return Attr{
		Key: key,
		Value: attrValue{
			num: uint64(len(value)),
			ext: uint64(uintptr(unsafe.Pointer(unsafe.SliceData(value)))),
		},
		kind: ValueKindGroup,
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
