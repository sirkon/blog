package attribute

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
	ValueKindBool                     ValueKind = 6
	ValueKindTime                     ValueKind = 7
	ValueKindDuration                 ValueKind = 8
	ValueKindInt                      ValueKind = 9
	ValueKindInt8                     ValueKind = 10
	ValueKindInt16                    ValueKind = 11
	ValueKindInt32                    ValueKind = 12
	ValueKindInt64                    ValueKind = 13
	ValueKindUint                     ValueKind = 14
	ValueKindUint8                    ValueKind = 15
	ValueKindUint16                   ValueKind = 16
	ValueKindUint32                   ValueKind = 17
	ValueKindUint64                   ValueKind = 18
	ValueKindFloat32                  ValueKind = 19
	ValueKindFloat64                  ValueKind = 20
	ValueKindString                   ValueKind = 21
	ValueKindBytes                    ValueKind = 22
	ValueKindErrorRaw                 ValueKind = 23
	ValueKindError                    ValueKind = 24
	ValueKindSerializer               ValueKind = 25
	ValueKindSliceBool                ValueKind = 26
	ValueKindSliceInt                 ValueKind = 27
	ValueKindSliceInt8                ValueKind = 28
	ValueKindSliceInt16               ValueKind = 29
	ValueKindSliceInt32               ValueKind = 30
	ValueKindSliceInt64               ValueKind = 31
	ValueKindSliceUint                ValueKind = 32
	ValueKindSliceUint8               ValueKind = 33
	ValueKindSliceUint16              ValueKind = 34
	ValueKindSliceUint32              ValueKind = 35
	ValueKindSliceUint64              ValueKind = 36
	ValueKindSliceFloat32             ValueKind = 37
	ValueKindSliceFloat64             ValueKind = 38
	ValueKindSliceString              ValueKind = 39
	ValueKindGroup                    ValueKind = 40

	ValueKindMax ValueKind = 255

	ValueKnownUserID = 1 << 8

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

var FixedFields []string = []string{
	"user-id",
}
