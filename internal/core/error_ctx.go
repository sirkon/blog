package core

import (
	"fmt"
	"time"
)

func (e *Error) Bool(key string, value bool) *Error {
	return e.insert(Bool(key, value))
}

func (e *Error) Time(key string, value time.Time) *Error {
	return e.insert(Time(key, value))
}

func (e *Error) Duration(key string, value time.Duration) *Error {
	return e.insert(Duration(key, value))
}

func (e *Error) Int(key string, value int) *Error {
	return e.insert(Int(key, value))
}

func (e *Error) Int8(key string, value int8) *Error {
	return e.insert(Int8(key, value))
}

func (e *Error) Int16(key string, value int16) *Error {
	return e.insert(Int16(key, value))
}

func (e *Error) Int32(key string, value int32) *Error {
	return e.insert(Int32(key, value))
}

func (e *Error) Int64(key string, value int64) *Error {
	return e.insert(Int64(key, value))
}

func (e *Error) Uint(key string, value uint) *Error {
	return e.insert(Uint(key, value))
}

func (e *Error) Uint8(key string, value uint8) *Error {
	return e.insert(Uint8(key, value))
}

func (e *Error) Uint16(key string, value uint16) *Error {
	return e.insert(Uint16(key, value))
}

func (e *Error) Uint32(key string, value uint32) *Error {
	return e.insert(Uint32(key, value))
}

func (e *Error) Uint64(key string, value uint64) *Error {
	return e.insert(Uint64(key, value))
}

func (e *Error) Flt32(key string, value float32) *Error {
	return e.insert(Flt32(key, value))
}

func (e *Error) Flt64(key string, value float64) *Error {
	return e.insert(Flt64(key, value))
}

func (e *Error) Str(key string, value string) *Error {
	return e.insert(Str(key, value))
}

func (e *Error) Stg(key string, value fmt.Stringer) *Error {
	return e.insert(Stg(key, value))
}

func (e *Error) Bytes(key string, value []byte) *Error {
	return e.insert(Bytes(key, value))
}

func (e *Error) Bools(key string, value []bool) *Error {
	return e.insert(Bools(key, value))
}

func (e *Error) Ints(key string, value []int) *Error {
	return e.insert(Ints(key, value))
}

func (e *Error) Int8s(key string, value []int8) *Error {
	return e.insert(Int8s(key, value))
}

func (e *Error) Int16s(key string, value []int16) *Error {
	return e.insert(Int16s(key, value))
}

func (e *Error) Int32s(key string, value []int32) *Error {
	return e.insert(Int32s(key, value))
}

func (e *Error) Int64s(key string, value []int64) *Error {
	return e.insert(Int64s(key, value))
}

func (e *Error) Uints(key string, value []uint) *Error {
	return e.insert(Uints(key, value))
}

func (e *Error) Uint8s(key string, value []uint8) *Error {
	return e.insert(Uint8s(key, value))
}

func (e *Error) Uint16s(key string, value []uint16) *Error {
	return e.insert(Uint16s(key, value))
}

func (e *Error) Uint32s(key string, value []uint32) *Error {
	return e.insert(Uint32s(key, value))
}

func (e *Error) Uint64s(key string, value []uint64) *Error {
	return e.insert(Uint64s(key, value))
}

func (e *Error) Flt32s(key string, value []float32) *Error {
	return e.insert(Flt32s(key, value))
}

func (e *Error) Flt64s(key string, value []float64) *Error {
	return e.insert(Flt64s(key, value))
}

func (e *Error) Strs(key string, value []string) *Error {
	return e.insert(Strs(key, value))
}

func (e *Error) insert(attr Attr) *Error {
	e.payload = AppendSerialized(e.payload, attr)
	return e
}
