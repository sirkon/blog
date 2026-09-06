package core

import (
	"fmt"
)

type ValueKind byte

const (
	// Group 1: special types 0..31.

	ValueKindTime     ValueKind = 0
	ValueKindDuration ValueKind = 1
	ValueKindErrorRaw ValueKind = 2
	ValueKindIvar     ValueKind = 16
	ValueKindUvar     ValueKind = 17

	// ----------------------------
	// Group 2: basic types. 32..63.

	ValueKindBool    ValueKind = 32
	ValueKindString  ValueKind = 33
	ValueKindInt8    ValueKind = 40
	ValueKindInt16   ValueKind = 41
	ValueKindInt32   ValueKind = 42
	ValueKindInt64   ValueKind = 43
	ValueKindUint8   ValueKind = 48
	ValueKindUint16  ValueKind = 49
	ValueKindUint32  ValueKind = 50
	ValueKindUint64  ValueKind = 51
	ValueKindFloat32 ValueKind = 56
	ValueKindFloat64 ValueKind = 57

	// ------------------------------
	// Group 3: slices of basic types.

	ValueKindSliceBool    ValueKind = 64
	ValueKindSliceString  ValueKind = 65
	ValueKindSliceInt8    ValueKind = 72
	ValueKindSliceInt16   ValueKind = 73
	ValueKindSliceInt32   ValueKind = 74
	ValueKindSliceInt64   ValueKind = 75
	ValueKindSliceUint8   ValueKind = 80
	ValueKindSliceUint16  ValueKind = 81
	ValueKindSliceUint32  ValueKind = 82
	ValueKindSliceUint64  ValueKind = 83
	ValueKindSliceFloat32 ValueKind = 88
	ValueKindSliceFloat64 ValueKind = 89

	// ------------------------------------------
	// Group 4: tree nodes and metadata: 128..255.

	ValueKindNewNode            ValueKind = 128
	ValueKindWrapNode           ValueKind = 129
	ValueKindJustContextNode    ValueKind = 130
	ValueKindLocationNode       ValueKind = 131
	ValueKindForeignErrorText   ValueKind = 132
	ValueKindPhantomContextNode ValueKind = 133
	ValueKindGroup              ValueKind = 134
	ValueKindError              ValueKind = 135
	ValueKindErrorEmbed         ValueKind = 136
	ValueKindGroupEnd           ValueKind = 137
)

// Compile-time guards: each array index below must be 0, i.e. the constant
// must keep its exact expected value. Any change breaks wire format
// compatibility and will not compile.
var (
	_ = [1]struct{}{}[ValueKindTime-0]
	_ = [1]struct{}{}[ValueKindDuration-1]
	_ = [1]struct{}{}[ValueKindErrorRaw-2]
	_ = [1]struct{}{}[ValueKindIvar-16]
	_ = [1]struct{}{}[ValueKindUvar-17]

	_ = [1]struct{}{}[ValueKindBool-32]
	_ = [1]struct{}{}[ValueKindString-33]
	_ = [1]struct{}{}[ValueKindInt8-40]
	_ = [1]struct{}{}[ValueKindInt16-41]
	_ = [1]struct{}{}[ValueKindInt32-42]
	_ = [1]struct{}{}[ValueKindInt64-43]
	_ = [1]struct{}{}[ValueKindUint8-48]
	_ = [1]struct{}{}[ValueKindUint16-49]
	_ = [1]struct{}{}[ValueKindUint32-50]
	_ = [1]struct{}{}[ValueKindUint64-51]
	_ = [1]struct{}{}[ValueKindFloat32-56]
	_ = [1]struct{}{}[ValueKindFloat64-57]

	_ = [1]struct{}{}[ValueKindSliceBool-64]
	_ = [1]struct{}{}[ValueKindSliceString-65]
	_ = [1]struct{}{}[ValueKindSliceInt8-72]
	_ = [1]struct{}{}[ValueKindSliceInt16-73]
	_ = [1]struct{}{}[ValueKindSliceInt32-74]
	_ = [1]struct{}{}[ValueKindSliceInt64-75]
	_ = [1]struct{}{}[ValueKindSliceUint8-80]
	_ = [1]struct{}{}[ValueKindSliceUint16-81]
	_ = [1]struct{}{}[ValueKindSliceUint32-82]
	_ = [1]struct{}{}[ValueKindSliceUint64-83]
	_ = [1]struct{}{}[ValueKindSliceFloat32-88]
	_ = [1]struct{}{}[ValueKindSliceFloat64-89]

	_ = [1]struct{}{}[ValueKindNewNode-128]
	_ = [1]struct{}{}[ValueKindWrapNode-129]
	_ = [1]struct{}{}[ValueKindJustContextNode-130]
	_ = [1]struct{}{}[ValueKindLocationNode-131]
	_ = [1]struct{}{}[ValueKindForeignErrorText-132]
	_ = [1]struct{}{}[ValueKindPhantomContextNode-133]
	_ = [1]struct{}{}[ValueKindGroup-134]
	_ = [1]struct{}{}[ValueKindError-135]
	_ = [1]struct{}{}[ValueKindErrorEmbed-136]
	_ = [1]struct{}{}[ValueKindGroupEnd-137]
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
		return "[]byte"
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
