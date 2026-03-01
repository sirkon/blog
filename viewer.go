package blog

import (
	"encoding/binary"
	"fmt"
	"math"
	"time"

	"github.com/sirkon/blog/internal/core"
)

// RecordConsumer API to consume record data.
type RecordConsumer interface {
	fmt.Stringer
	Reset()

	SetTime(timeUnixNano uint64)
	SetLevel(level core.LoggingLevel)
	SetLocation(file string, line int)
	SetMessage(text string)

	RootAttrConsumer() RecordAttributesConsumer
}

// RecordAttributesConsumer API to consume record attributes.
type RecordAttributesConsumer interface {
	Append(key string, value any)
	AppendGroup(key string) RecordAttributesConsumer
	AppendEmptyGroup(key string) RecordAttributesConsumer
	AppendError(key string) RecordAttributesConsumer
	Finish() RecordAttributesConsumer
}

// RecordSafeView provides human-readable output over [Logger] produced binary stream.
// The input data considered to be safe, so no 0xFF, CRC32 and length will be made.
//
// It is aimed at maximum readability for debug runs, the speed is out of equation.
func RecordSafeView(cons RecordConsumer, data []byte) error {
	// Pass 0xFF, CRC32 and record length.
	data = data[5:]
	_, varintLength := binary.Uvarint(data)
	data = data[varintLength:]

	// So, we have a record content in our hands.
	tim := binary.LittleEndian.Uint64(data)
	cons.SetTime(tim)
	cons.SetLevel(core.LoggingLevel(data[8]))
	data = data[9:]

	// Check if is there a location.
	if data[0] != 0 {
		length, varintLength := binary.Uvarint(data)
		file := string(data[varintLength : varintLength+int(length)])
		data = data[varintLength+int(length):]
		line, varintLength := binary.Uvarint(data)
		data = data[varintLength:]
		cons.SetLocation(file, int(line))
	} else {
		data = data[10:]
	}

	// Message.
	length, varintLength := binary.Uvarint(data)
	cons.SetMessage(string(data[varintLength : varintLength+int(length)]))
	data = data[varintLength+int(length):]

	// Payload in
	attrCons := cons.RootAttrConsumer()
	consumeContext(attrCons, data, -1)

	return nil
}

func consumeContext(cons RecordAttributesConsumer, src []byte, width int) []byte {
	var count int

	for len(src) > 0 {
		count++
		if width >= 0 && count > width {
			break
		}

		kind := core.ValueKind(src[0])
		src = src[1:]
		switch kind {
		case core.ValueKindJustContextNode, core.ValueKindJustContextInheritedNode:
			cons = cons.Finish()
			cons = cons.AppendGroup("CTX")
			continue
		}

		var key string
		if src[0] == 0 {
			keyCode, varintLength := binary.Uvarint(src[1:])
			key = core.PredefinedKeys[keyCode]
			src = src[varintLength+1:]
		} else {
			length, varintLength := binary.Uvarint(src)
			key = string(src[varintLength : varintLength+int(length)])
			src = src[varintLength+int(length):]
		}

		switch kind {
		case core.ValueKindNewNode:
			cons = cons.Finish()
			cons = cons.AppendGroup("NEW: " + key)
		case core.ValueKindWrapNode:
			cons = cons.Finish()
			cons = cons.AppendGroup("WRAP: " + key)
		case core.ValueKindWrapInheritedNode:
			cons = cons.Finish()
			cons = cons.AppendGroup("WRAP: " + key)
		case core.ValueKindLocationNode:
			line, varintLengh := binary.Uvarint(src)
			src = src[varintLengh:]
			cons.Append("@location", fmt.Sprintf("%s:%d", key, line))
		case core.ValueKindBool:
			cons.Append(key, src[0] != 0)
			src = src[1:]
		case core.ValueKindTime:
			tim := binary.LittleEndian.Uint64(src)
			cons.Append(key, time.Unix(0, int64(tim)))
			src = src[8:]
		case core.ValueKindDuration:
			dur := binary.LittleEndian.Uint64(src)
			cons.Append(key, time.Duration(dur))
			src = src[8:]
		case core.ValueKindInt:
			val := binary.LittleEndian.Uint64(src)
			cons.Append(key, int(val))
			src = src[8:]
		case core.ValueKindInt8:
			cons.Append(key, int8(src[0]))
			src = src[1:]
		case core.ValueKindInt16:
			val := binary.LittleEndian.Uint16(src)
			cons.Append(key, int16(val))
			src = src[2:]
		case core.ValueKindInt32:
			val := binary.LittleEndian.Uint32(src)
			cons.Append(key, int32(val))
			src = src[4:]
		case core.ValueKindInt64:
			val := binary.LittleEndian.Uint64(src)
			cons.Append(key, int64(val))
			src = src[8:]
		case core.ValueKindUint:
			val := binary.LittleEndian.Uint64(src)
			cons.Append(key, uint(val))
			src = src[8:]
		case core.ValueKindUint8:
			cons.Append(key, src[0])
			src = src[1:]
		case core.ValueKindUint16:
			val := binary.LittleEndian.Uint16(src)
			cons.Append(key, val)
			src = src[2:]
		case core.ValueKindUint32:
			val := binary.LittleEndian.Uint32(src)
			cons.Append(key, val)
			src = src[4:]
		case core.ValueKindUint64:
			val := binary.LittleEndian.Uint64(src)
			cons.Append(key, val)
			src = src[8:]
		case core.ValueKindFloat32:
			val := binary.LittleEndian.Uint32(src)
			cons.Append(key, math.Float32frombits(val))
			src = src[4:]
		case core.ValueKindFloat64:
			val := binary.LittleEndian.Uint64(src)
			cons.Append(key, math.Float64frombits(val))
			src = src[8:]
		case core.ValueKindString:
			length, varintLength := binary.Uvarint(src)
			cons.Append(key, string(src[varintLength:varintLength+int(length)]))
			src = src[varintLength+int(length):]
		case core.ValueKindBytes:
			length, varintLength := binary.Uvarint(src)
			cons.Append(key, src[varintLength:varintLength+int(length)])
			src = src[varintLength+int(length):]
		case core.ValueKindErrorRaw:
			length, varintLength := binary.Uvarint(src)
			cons.Append(key, string(src[varintLength:varintLength+int(length)]))
			src = src[varintLength+int(length):]
		case core.ValueKindError:
			group := cons.AppendGroup(key)
			length, varintLength := binary.Uvarint(src)
			errPayload := src[varintLength : varintLength+int(length)]
			errMsg := core.SufficientErrorBytes(errPayload)
			group.Append("text", string(errMsg))
			appendGroup := group.AppendEmptyGroup("@context")
			consumeContext(appendGroup, errPayload, -1)
			src = src[varintLength+int(length):]
		case core.ValueKindErrorEmbed:
			length, varintLength := binary.Uvarint(src)
			errMsg := src[varintLength : varintLength+int(length)]
			src = src[varintLength+int(length):]
			group := cons.AppendGroup(key)
			group.Append("text", string(errMsg))
			length, varintLength = binary.Uvarint(src)
			appendGroup := group.AppendEmptyGroup("@context")
			consumeContext(appendGroup, src[varintLength:varintLength+int(length)], -1)
			src = src[varintLength+int(length):]
		case core.ValueKindSliceBool:
			length, varintLength := binary.Uvarint(src)
			src = src[varintLength:]
			slice := make([]bool, length)
			for i := range length {
				slice[i] = src[i] != 0
			}
			cons.Append(key, slice)
			src = src[length:]
		case core.ValueKindSliceInt:
			length, varintLength := binary.Uvarint(src)
			src = src[varintLength:]
			slice := make([]int, length)
			for i := range length {
				v := binary.LittleEndian.Uint64(src)
				slice[i] = int(v)
				src = src[8:]
			}
			cons.Append(key, slice)
		case core.ValueKindSliceInt8:
			length, varintLength := binary.Uvarint(src)
			src = src[varintLength:]
			slice := make([]int8, length)
			for i := range length {
				slice[i] = int8(src[i])
			}
			cons.Append(key, slice)
			src = src[length:]
		case core.ValueKindSliceInt16:
			length, varintLength := binary.Uvarint(src)
			src = src[varintLength:]
			slice := make([]int16, length)
			for i := range length {
				v := binary.LittleEndian.Uint16(src)
				slice[i] = int16(v)
				src = src[2:]
			}
			cons.Append(key, slice)
		case core.ValueKindSliceInt32:
			length, varintLength := binary.Uvarint(src)
			src = src[varintLength:]
			slice := make([]int32, length)
			for i := range length {
				v := binary.LittleEndian.Uint32(src)
				slice[i] = int32(v)
				src = src[4:]
			}
			cons.Append(key, slice)
		case core.ValueKindSliceInt64:
			length, varintLength := binary.Uvarint(src)
			src = src[varintLength:]
			slice := make([]int64, length)
			for i := range length {
				v := binary.LittleEndian.Uint64(src)
				slice[i] = int64(v)
				src = src[8:]
			}
			cons.Append(key, slice)
		case core.ValueKindSliceUint:
			length, varuintLength := binary.Uvarint(src)
			src = src[varuintLength:]
			slice := make([]uint, length)
			for i := range length {
				v := binary.LittleEndian.Uint64(src)
				slice[i] = uint(v)
				src = src[8:]
			}
			cons.Append(key, slice)
		case core.ValueKindSliceUint8:
			length, varuintLength := binary.Uvarint(src)
			src = src[varuintLength:]
			slice := make([]uint8, length)
			for i := range length {
				slice[i] = src[i]
			}
			cons.Append(key, slice)
			src = src[length:]
		case core.ValueKindSliceUint16:
			length, varuintLength := binary.Uvarint(src)
			src = src[varuintLength:]
			slice := make([]uint16, length)
			for i := range length {
				v := binary.LittleEndian.Uint16(src)
				slice[i] = v
				src = src[2:]
			}
			cons.Append(key, slice)
		case core.ValueKindSliceUint32:
			length, varuintLength := binary.Uvarint(src)
			src = src[varuintLength:]
			slice := make([]uint32, length)
			for i := range length {
				v := binary.LittleEndian.Uint32(src)
				slice[i] = v
				src = src[4:]
			}
			cons.Append(key, slice)
		case core.ValueKindSliceUint64:
			length, varuintLength := binary.Uvarint(src)
			src = src[varuintLength:]
			slice := make([]uint64, length)
			for i := range length {
				v := binary.LittleEndian.Uint64(src)
				slice[i] = v
				src = src[8:]
			}
			cons.Append(key, slice)

		case core.ValueKindSliceFloat32:
			length, varfloatLength := binary.Uvarint(src)
			src = src[varfloatLength:]
			slice := make([]float32, length)
			for i := range length {
				v := binary.LittleEndian.Uint32(src)
				slice[i] = math.Float32frombits(v)
				src = src[4:]
			}
			cons.Append(key, slice)
		case core.ValueKindSliceFloat64:
			length, varfloatLength := binary.Uvarint(src)
			src = src[varfloatLength:]
			slice := make([]float64, length)
			for i := range length {
				v := binary.LittleEndian.Uint64(src)
				slice[i] = math.Float64frombits(v)
				src = src[8:]
			}
			cons.Append(key, slice)
		case core.ValueKindSliceString:
			length, varintLength := binary.Uvarint(src)
			src = src[varintLength:]
			slice := make([]string, length)
			for i := range length {
				length, varintLength = binary.Uvarint(src)
				src = src[varintLength:]
				slice[i] = string(src[:length])
				src = src[length:]
			}
			cons.Append(key, slice)

		case core.ValueKindGroup:
			length, varintLength := binary.Uvarint(src)
			src = src[varintLength:]
			src = consumeContext(cons.AppendGroup(key), src, int(length))
		}
	}

	return src
}
