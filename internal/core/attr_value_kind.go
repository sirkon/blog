package core

import (
	"fmt"
)

type ValueKind uint64

const (
	valueKindInvalid                  ValueKind = 0
	ValueKindNewNode                  ValueKind = 1
	ValueKindWrapNode                 ValueKind = 2
	ValueKindWrapInheritedNode        ValueKind = 3
	ValueKindJustContextNode          ValueKind = 4
	ValueKindJustContextInheritedNode ValueKind = 5
	ValueKindLocationNode             ValueKind = 6
	ValueKindBool                     ValueKind = 8
	ValueKindTime                     ValueKind = 9
	ValueKindDuration                 ValueKind = 10
	ValueKindInt                      ValueKind = 11
	ValueKindInt8                     ValueKind = 12
	ValueKindInt16                    ValueKind = 13
	ValueKindInt32                    ValueKind = 14
	ValueKindInt64                    ValueKind = 15
	ValueKindUint                     ValueKind = 16
	ValueKindUint8                    ValueKind = 17
	ValueKindUint16                   ValueKind = 18
	ValueKindUint32                   ValueKind = 19
	ValueKindUint64                   ValueKind = 20
	ValueKindFloat32                  ValueKind = 21
	ValueKindFloat64                  ValueKind = 22
	ValueKindString                   ValueKind = 23
	ValueKindBytes                    ValueKind = 24
	ValueKindErrorRaw                 ValueKind = 25
	ValueKindError                    ValueKind = 26
	ValueKindSerializer               ValueKind = 27
	ValueKindSliceBool                ValueKind = 28
	ValueKindSliceInt                 ValueKind = 29
	ValueKindSliceInt8                ValueKind = 30
	ValueKindSliceInt16               ValueKind = 31
	ValueKindSliceInt32               ValueKind = 32
	ValueKindSliceInt64               ValueKind = 33
	ValueKindSliceUint                ValueKind = 34
	ValueKindSliceUint8               ValueKind = 35
	ValueKindSliceUint16              ValueKind = 36
	ValueKindSliceUint32              ValueKind = 37
	ValueKindSliceUint64              ValueKind = 38
	ValueKindSliceFloat32             ValueKind = 39
	ValueKindSliceFloat64             ValueKind = 40
	ValueKindSliceString              ValueKind = 41
	ValueKindGroup                    ValueKind = 42

	ValueKindMax ValueKind = 255

	ValueKnownUserID = 1 + 1<<8

	// There're ValueKind values at 257 and further to represent [Attr] with predefined keys, where their
	// lowest byte represents a kind and the upper 7 bytes refer a key index.
)

func (k ValueKind) String() string {
	switch k {
	case ValueKindBool:
		return "bool"
	case ValueKindTime:
		return "time.UnixNano"
	case ValueKindDuration:
		return "time.Duration"
	case ValueKindInt:
		return "int"
	case ValueKindInt8:
		return "int8"
	case ValueKindInt16:
		return "int16"
	case ValueKindInt32:
		return "int32"
	case ValueKindInt64:
		return "int64"
	case ValueKindUint:
		return "uint"
	case ValueKindUint8:
		return "uint8"
	case ValueKindUint16:
		return "uint16"
	case ValueKindUint32:
		return "uint32"
	case ValueKindUint64:
		return "uint64"
	case ValueKindFloat32:
		return "float32"
	case ValueKindFloat64:
		return "float64"
	case ValueKindString:
		return "string"
	case ValueKindBytes:
		return "[]byte"
	case ValueKindErrorRaw:
		return "error"
	case ValueKindError:
		return "beer.Error"
	case ValueKindSerializer:
		return "blog.Serializable"
	case ValueKindSliceBool:
		return "[]bool"
	case ValueKindSliceInt:
		return "[]int"
	case ValueKindSliceInt8:
		return "[]int8"
	case ValueKindSliceInt16:
		return "[]int16"
	case ValueKindSliceInt32:
		return "[]int32"
	case ValueKindSliceInt64:
		return "[]int64"
	case ValueKindSliceUint:
		return "[]uint"
	case ValueKindSliceUint8:
		return "[]uint8"
	case ValueKindSliceUint16:
		return "[]uint16"
	case ValueKindSliceUint32:
		return "[]uint32"
	case ValueKindSliceUint64:
		return "[]uint64"
	case ValueKindSliceFloat32:
		return "[]float32"
	case ValueKindSliceFloat64:
		return "[]float64"
	case ValueKindSliceString:
		return "[]string"
	case ValueKindGroup:
		return "blog.Group"
	default:
		return fmt.Sprintf("value-kind-unknown[%d]", k)
	}
}

// PredefinedKeys keys can be set via the extension of kind in the
// higher 7 bytes of uint64. That extended bytes keep an index of
// the key value in this slice.
var PredefinedKeys []string = []string{
	"user-id",
}
