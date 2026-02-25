package attribute

import (
	"fmt"
)

type ValueKind uint64

const (
	valueKindInvalid ValueKind = iota
	ValueKindNewNode
	ValueKindWrapNode
	ValueKindWrapInheritedNode
	ValueKindJustContextNode
	ValueKindJustInheritedContextNode
	ValueKindBool
	ValueKindTime
	ValueKindDuration
	ValueKindInt
	ValueKindInt8
	ValueKindInt16
	ValueKindInt32
	ValueKindInt64
	ValueKindUint
	ValueKindUint8
	ValueKindUint16
	ValueKindUint32
	ValueKindUint64
	ValueKindFloat32
	ValueKindFloat64
	ValueKindString
	ValueKindBytes
	ValueKindErrorRaw
	ValueKindError
	ValueKindSerializer
	ValueKindSliceBool
	ValueKindSliceInt
	ValueKindSliceInt8
	ValueKindSliceInt16
	ValueKindSliceInt32
	ValueKindSliceInt64
	ValueKindSliceUint
	ValueKindSliceUint8
	ValueKindSliceUint16
	ValueKindSliceUint32
	ValueKindSliceUint64
	ValueKindSliceFloat32
	ValueKindSliceFloat64
	ValueKindSliceString
	ValueKindSliceGroup

	ValueKindMax ValueKind = 255

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
	case ValueKindSliceGroup:
		return "blog.Group"
	default:
		return fmt.Sprintf("value-kind-unknown[%d]", k)
	}
}
