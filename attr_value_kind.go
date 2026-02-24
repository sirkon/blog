package blog

import (
	"fmt"
)

type valueKind uint64

const (
	valueKindInvalid valueKind = iota
	valueKindBool
	valueKindTime
	valueKindDuration
	valueKindInt
	valueKindInt8
	valueKindInt16
	valueKindInt32
	valueKindInt64
	valueKindUint
	valueKindUint8
	valueKindUint16
	valueKindUint32
	valueKindUint64
	valueKindFloat32
	valueKindFloat64
	valueKindString
	valueKindBytes
	valueKindErrorRaw
	valueKindError
	valueKindSerializable
	valueKindSliceBool
	valueKindSliceInt
	valueKindSliceInt8
	valueKindSliceInt16
	valueKindSliceInt32
	valueKindSliceInt64
	valueKindSliceUint
	valueKindSliceUint8
	valueKindSliceUint16
	valueKindSliceUint32
	valueKindSliceUint64
	valueKindSliceFloat32
	valueKindSliceFloat64
	valueKindSliceString

	valueKindMax valueKind = 255

	// There're valueKind values at 257 and further to represent [Attr] with predefined keys, where their
	// lowest byte represents a kind and the upper 7 bytes refer a key index.
)

func (k valueKind) String() string {
	switch k {
	case valueKindBool:
		return "bool"
	case valueKindTime:
		return "time.UnixNano"
	case valueKindDuration:
		return "time.Duration"
	case valueKindInt:
		return "int"
	case valueKindInt8:
		return "int8"
	case valueKindInt16:
		return "int16"
	case valueKindInt32:
		return "int32"
	case valueKindInt64:
		return "int64"
	case valueKindUint:
		return "uint"
	case valueKindUint8:
		return "uint8"
	case valueKindUint16:
		return "uint16"
	case valueKindUint32:
		return "uint32"
	case valueKindUint64:
		return "uint64"
	case valueKindFloat32:
		return "float32"
	case valueKindFloat64:
		return "float64"
	case valueKindString:
		return "string"
	case valueKindBytes:
		return "[]byte"
	case valueKindErrorRaw:
		return "error"
	case valueKindError:
		return "beer.Error"
	case valueKindSerializable:
		return "blog.Serializable"
	case valueKindSliceBool:
		return "[]bool"
	case valueKindSliceInt:
		return "[]int"
	case valueKindSliceInt8:
		return "[]int8"
	case valueKindSliceInt16:
		return "[]int16"
	case valueKindSliceInt32:
		return "[]int32"
	case valueKindSliceInt64:
		return "[]int64"
	case valueKindSliceUint:
		return "[]uint"
	case valueKindSliceUint8:
		return "[]uint8"
	case valueKindSliceUint16:
		return "[]uint16"
	case valueKindSliceUint32:
		return "[]uint32"
	case valueKindSliceUint64:
		return "[]uint64"
	case valueKindSliceFloat32:
		return "[]float32"
	case valueKindSliceFloat64:
		return "[]float64"
	case valueKindSliceString:
		return "[]string"
	default:
		return fmt.Sprintf("unknown-value-kind[%d]", k)
	}
}
