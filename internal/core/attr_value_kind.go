package core

import (
	"fmt"
)

type ValueKind byte

const (
	valueKindInvalid ValueKind = iota // 0

	// --- Group 1: tree nodes and metadata ---
	ValueKindNewNode
	ValueKindWrapNode
	ValueKindJustContextNode
	ValueKindLocationNode
	ValueKindForeignErrorText
	ValueKindPhantomContextNode
	ValueKindGroup
	ValueKindError
	ValueKindErrorEmbed
	ValueKindGroupEnd

	// --- Group 2: Payload / base types ---
	ValueKindBool
	ValueKindTime
	ValueKindDuration
	ValueKindIvar
	ValueKindInt8
	ValueKindInt16
	ValueKindInt32
	ValueKindInt64
	ValueKindUvar
	ValueKindUint8
	ValueKindUint16
	ValueKindUint32
	ValueKindUint64
	ValueKindFloat32
	ValueKindFloat64
	ValueKindString
	ValueKindBytes
	ValueKindErrorRaw

	// --- Group 3: Slices ---
	ValueKindSliceBool
	ValueKindSliceInt8
	ValueKindSliceInt16
	ValueKindSliceInt32
	ValueKindSliceInt64
	ValueKindSliceUint8
	ValueKindSliceUint16
	ValueKindSliceUint32
	ValueKindSliceUint64
	ValueKindSliceFloat32
	ValueKindSliceFloat64
	ValueKindSliceString
)

func (k ValueKind) String() string {
	switch k & 0xFF {
	case ValueKindNewNode:
		return "NewNode"
	case ValueKindWrapNode:
		return "WrapNode"
	case ValueKindJustContextNode:
		return "JustContextNode"
	case ValueKindLocationNode:
		return "LocationNode"
	case ValueKindForeignErrorText:
		return "ForeignErrorText"
	case ValueKindPhantomContextNode:
		return "PhantomContextNode"
	case ValueKindGroup:
		return "blog.Group"
	case ValueKindError:
		return "beer.Error"
	case ValueKindErrorEmbed:
		return "ForeignWrap(beer.Error)"
	case ValueKindGroupEnd:
		return "group.end"
	case ValueKindBool:
		return "bool"
	case ValueKindTime:
		return "time.UnixNano"
	case ValueKindDuration:
		return "time.Duration"
	case ValueKindInt8:
		return "int8"
	case ValueKindInt16:
		return "int16"
	case ValueKindInt32:
		return "int32"
	case ValueKindInt64:
		return "int64"
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
	case ValueKindSliceBool:
		return "[]bool"
	case ValueKindSliceInt8:
		return "[]int8"
	case ValueKindSliceInt16:
		return "[]int16"
	case ValueKindSliceInt32:
		return "[]int32"
	case ValueKindSliceInt64:
		return "[]int64"
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
	default:
		return fmt.Sprintf("spec-kind-unknown[%d]", k)
	}
}

type PredefinedKeyCode uint64

func PredefinedKey(code PredefinedKeyCode) string {
	switch code {
	default:
		return fmt.Sprintf("predefined-key-code-unknown(%d)", code)
	}
}

const (
	predefinedKeyCodeUnknown PredefinedKeyCode = iota
)

// compile-time checks for ABI compatibility.
func _() {
	var check [1]struct{}

	_ = check[valueKindInvalid]

	// Group 1
	_ = check[byte(ValueKindNewNode)-1]
	_ = check[byte(ValueKindWrapNode)-2]
	_ = check[byte(ValueKindJustContextNode)-3]
	_ = check[byte(ValueKindLocationNode)-4]
	_ = check[byte(ValueKindForeignErrorText)-5]
	_ = check[byte(ValueKindPhantomContextNode)-6]
	_ = check[byte(ValueKindGroup)-7]
	_ = check[byte(ValueKindError)-8]
	_ = check[byte(ValueKindErrorEmbed)-9]
	_ = check[byte(ValueKindGroupEnd)-10]

	// Group 2
	_ = check[byte(ValueKindBool)-11]
	_ = check[byte(ValueKindTime)-12]
	_ = check[byte(ValueKindDuration)-13]
	_ = check[byte(ValueKindIvar)-14]
	_ = check[byte(ValueKindInt8)-15]
	_ = check[byte(ValueKindInt16)-16]
	_ = check[byte(ValueKindInt32)-17]
	_ = check[byte(ValueKindInt64)-18]
	_ = check[byte(ValueKindUvar)-19]
	_ = check[byte(ValueKindUint8)-20]
	_ = check[byte(ValueKindUint16)-21]
	_ = check[byte(ValueKindUint32)-22]
	_ = check[byte(ValueKindUint64)-23]
	_ = check[byte(ValueKindFloat32)-24]
	_ = check[byte(ValueKindFloat64)-25]
	_ = check[byte(ValueKindString)-26]
	_ = check[byte(ValueKindBytes)-27]
	_ = check[byte(ValueKindErrorRaw)-28]

	// Group 3
	_ = check[byte(ValueKindSliceBool)-29]
	_ = check[byte(ValueKindSliceInt8)-30]
	_ = check[byte(ValueKindSliceInt16)-31]
	_ = check[byte(ValueKindSliceInt32)-32]
	_ = check[byte(ValueKindSliceInt64)-33]
	_ = check[byte(ValueKindSliceUint8)-34]
	_ = check[byte(ValueKindSliceUint16)-35]
	_ = check[byte(ValueKindSliceUint32)-36]
	_ = check[byte(ValueKindSliceUint64)-37]
	_ = check[byte(ValueKindSliceFloat32)-38]
	_ = check[byte(ValueKindSliceFloat64)-39]
	_ = check[byte(ValueKindSliceString)-40]
}
