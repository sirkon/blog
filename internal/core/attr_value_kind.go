package core

import (
	"fmt"
)

type ValueKind uint64

const (
	valueKindInvalid ValueKind = 0

	// --- Group 1: tree nodes and metadata  ---

	ValueKindNewNode                  ValueKind = 1
	ValueKindWrapNode                 ValueKind = 2
	ValueKindWrapInheritedNode        ValueKind = 3
	ValueKindJustContextNode          ValueKind = 4
	ValueKindJustContextInheritedNode ValueKind = 5
	ValueKindLocationNode             ValueKind = 6
	ValueKindForeignErrorText         ValueKind = 7
	ValueKindForeignErrorFormat       ValueKind = 8
	ValueKindSerializer               ValueKind = 9
	ValueKindPhantomContextNode       ValueKind = 10

	// --- Group 2: Payload / base types (32+) ---

	ValueKindBool     ValueKind = 32
	ValueKindTime     ValueKind = 33
	ValueKindDuration ValueKind = 34
	ValueKindInt      ValueKind = 35
	ValueKindInt8     ValueKind = 36
	ValueKindInt16    ValueKind = 37
	ValueKindInt32    ValueKind = 38
	ValueKindInt64    ValueKind = 39
	ValueKindUint     ValueKind = 40
	ValueKindUint8    ValueKind = 41
	ValueKindUint16   ValueKind = 42
	ValueKindUint32   ValueKind = 43
	ValueKindUint64   ValueKind = 44
	ValueKindFloat32  ValueKind = 45
	ValueKindFloat64  ValueKind = 46
	ValueKindString   ValueKind = 47
	ValueKindBytes    ValueKind = 48
	ValueKindErrorRaw ValueKind = 49

	// --- Group 3: Complex structs and slices (64+) ---

	// ValueKindError keeps just a collected payload and compute error
	// message based on it.
	ValueKindError ValueKind = 64
	// ValueKindErrorEmbed keeps an error AND a text at the same time.
	ValueKindErrorEmbed ValueKind = 65
	ValueKindGroup      ValueKind = 66

	ValueKindSliceBool    ValueKind = 70
	ValueKindSliceInt     ValueKind = 71
	ValueKindSliceInt8    ValueKind = 72
	ValueKindSliceInt16   ValueKind = 73
	ValueKindSliceInt32   ValueKind = 74
	ValueKindSliceInt64   ValueKind = 75
	ValueKindSliceUint    ValueKind = 76
	ValueKindSliceUint8   ValueKind = 77
	ValueKindSliceUint16  ValueKind = 78
	ValueKindSliceUint32  ValueKind = 79
	ValueKindSliceUint64  ValueKind = 80
	ValueKindSliceFloat32 ValueKind = 81
	ValueKindSliceFloat64 ValueKind = 82
	ValueKindSliceString  ValueKind = 83

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
