package blog

import (
	"fmt"
	"time"

	"github.com/sirkon/blog/internal/core"
)

// Attr is a type alias for [core.Attr]
//
//	type Attr struct {
//	    Key   string
//	    Value Value
//	}
type Attr = core.Attr

// Bool returns an [Attr] for boolean value.
func Bool(key string, value bool) Attr {
	return core.Bool(key, value)
}

// Time returns an [Attr] for time.Time.
func Time(key string, value time.Time) Attr {
	return core.Time(key, value)
}

// Duration returns an [Attr] for time.Duration.
func Duration(key string, value time.Duration) Attr {
	return core.Duration(key, value)
}

// Int returns an [Attr] for int value.
func Int(key string, value int) Attr {
	return core.Int(key, value)
}

// Int8 returns an [Attr] for int8 value.
func Int8(key string, value int8) Attr {
	return core.Int8(key, value)
}

// Int16 returns an [Attr] for int16 value.
func Int16(key string, value int16) Attr {
	return core.Int16(key, value)
}

// Int32 returns an [Attr] for int32 value.
func Int32(key string, value int32) Attr {
	return core.Int32(key, value)
}

// Int64 returns an [Attr] for int64 value.
func Int64(key string, value int64) Attr {
	return core.Int64(key, value)
}

// Uint returns an [Attr] for uint value.
func Uint(key string, value uint) Attr {
	return core.Uint(key, value)
}

// Uint8 returns an [Attr] for uint8 value.
func Uint8(key string, value uint8) Attr {
	return core.Uint8(key, value)
}

// Uint16 returns an [Attr] for uint16 value.
func Uint16(key string, value uint16) Attr {
	return core.Uint16(key, value)
}

// Uint32 returns an [Attr] for uint32 value.
func Uint32(key string, value uint32) Attr {
	return core.Uint32(key, value)
}

// Uint64 returns an [Attr] for uint64 value.
func Uint64(key string, value uint64) Attr {
	return core.Uint64(key, value)
}

// Flt32 returns an [Attr] for float32 value.
func Flt32(key string, value float32) Attr {
	return core.Flt32(key, value)
}

// Flt64 returns an [Attr] for float64 value.
func Flt64(key string, value float64) Attr {
	return core.Flt64(key, value)
}

// Str returns an [Attr] for string value.
func Str(key string, value string) Attr {
	return core.Str(key, value)
}

// Stg returns an [Attr] for fmt.Stringer value.
func Stg(key string, value fmt.Stringer) Attr {
	return core.Stg(key, value)
}

// Bytes returns an [Attr] for []byte value.
func Bytes(key string, value []byte) Attr {
	return core.Bytes(key, value)
}

// Error returns an [Attr] for error value.
func Error(key string, err error) Attr {
	return core.ErrorAttr(key, err)
}

// Err returns an [Attr] for error with key "err".
func Err(err error) Attr {
	return core.Err(err)
}

// Bools returns an [Attr] for []bool value.
func Bools(key string, value []bool) Attr {
	return core.Bools(key, value)
}

// Ints returns an [Attr] for []int value.
func Ints(key string, value []int) Attr {
	return core.Ints(key, value)
}

// Int8s returns an [Attr] for []int8 value.
func Int8s(key string, value []int8) Attr {
	return core.Int8s(key, value)
}

// Int16s returns an [Attr] for []int16 value.
func Int16s(key string, value []int16) Attr {
	return core.Int16s(key, value)
}

// Int32s returns an [Attr] for []int32 value.
func Int32s(key string, value []int32) Attr {
	return core.Int32s(key, value)
}

// Int64s returns an [Attr] for []int64 value.
func Int64s(key string, value []int64) Attr {
	return core.Int64s(key, value)
}

// Uints returns an [Attr] for []uint value.
func Uints(key string, value []uint) Attr {
	return core.Uints(key, value)
}

// Uint8s returns an [Attr] for []uint8 value.
func Uint8s(key string, value []uint8) Attr {
	return core.Uint8s(key, value)
}

// Uint16s returns an [Attr] for []uint16 value.
func Uint16s(key string, value []uint16) Attr {
	return core.Uint16s(key, value)
}

// Uint32s returns an [Attr] for []uint32 value.
func Uint32s(key string, value []uint32) Attr {
	return core.Uint32s(key, value)
}

// Uint64s returns an [Attr] for []uint64 value.
func Uint64s(key string, value []uint64) Attr {
	return core.Uint64s(key, value)
}

// Flt32s returns an [Attr] for []float32 value.
func Flt32s(key string, value []float32) Attr {
	return core.Flt32s(key, value)
}

// Flt64s returns an [Attr] for []float64 value.
func Flt64s(key string, value []float64) Attr {
	return core.Flt64s(key, value)
}

// Strs returns an [Attr] for []string value.
func Strs(key string, value []string) Attr {
	return core.Strs(key, value)
}

// Group returns an [Attr] for []Attr value.
func Group(key string, value ...Attr) Attr {
	return core.Group(key, value...)
}

// Obj returns an [Attr] for Serializer value.
func Obj(key string, value core.Serializer) Attr {
	return core.Obj(key, value)
}
