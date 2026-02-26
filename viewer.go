package blog

import (
	"encoding/binary"
	"fmt"
	"math"
	"time"

	"github.com/sirkon/blog/internal/attribute"
)

// RecordConsumer API to consume record data.
type RecordConsumer interface {
	fmt.Stringer
	Reset()

	SetTime(timeUnixNano uint64)
	SetLevel(level LoggingLevel)
	SetLocation(file string, line int)
	SetMessage(text string)

	RootAttrConsumer() RecordAttributesConsumer
}

// RecordAttributesConsumer API to consume record attributes.
type RecordAttributesConsumer interface {
	Append(key string, value any)
	AppendGroup(key string) RecordAttributesConsumer
	AppendError(key string) RecordAttributesConsumer
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
	cons.SetLevel(LoggingLevel(data[8]))
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

		var key string
		if src[0] == 0 {
			keyCode, varintLengh := binary.Uvarint(src[1:])
			key = attribute.PredefinedKeys[keyCode]
			src = src[varintLengh+1:]
		} else {
			length, varintLength := binary.Uvarint(src)
			key = string(src[varintLength : varintLength+int(length)])
			src = src[varintLength+int(length):]
		}

		kind := src[0]
		src = src[1:]
		switch attribute.ValueKind(kind) {
		case attribute.ValueKindBool:
			cons.Append(key, src[0] != 0)
			src = src[1:]
		case attribute.ValueKindTime:
			tim := binary.LittleEndian.Uint64(src)
			cons.Append(key, time.Unix(0, int64(tim)))
			src = src[8:]
		case attribute.ValueKindDuration:
			dur := binary.LittleEndian.Uint64(src)
			cons.Append(key, time.Duration(dur))
			src = src[8:]
		case attribute.ValueKindInt:
			val := binary.LittleEndian.Uint64(src)
			cons.Append(key, int(val))
			src = src[8:]
		case attribute.ValueKindInt8:
			cons.Append(key, int8(src[0]))
			src = src[1:]
		case attribute.ValueKindInt16:
			val := binary.LittleEndian.Uint16(src)
			cons.Append(key, int16(val))
			src = src[2:]
		case attribute.ValueKindInt32:
			val := binary.LittleEndian.Uint32(src)
			cons.Append(key, int32(val))
			src = src[4:]
		case attribute.ValueKindInt64:
			val := binary.LittleEndian.Uint64(src)
			cons.Append(key, int64(val))
			src = src[8:]
		case attribute.ValueKindUint:
			val := binary.LittleEndian.Uint64(src)
			cons.Append(key, uint(val))
			src = src[8:]
		case attribute.ValueKindUint8:
			cons.Append(key, src[0])
			src = src[1:]
		case attribute.ValueKindUint16:
			val := binary.LittleEndian.Uint16(src)
			cons.Append(key, val)
			src = src[2:]
		case attribute.ValueKindUint32:
			val := binary.LittleEndian.Uint32(src)
			cons.Append(key, val)
			src = src[4:]
		case attribute.ValueKindUint64:
			val := binary.LittleEndian.Uint64(src)
			cons.Append(key, val)
			src = src[8:]
		case attribute.ValueKindFloat32:
			val := binary.LittleEndian.Uint32(src)
			cons.Append(key, math.Float32frombits(val))
			src = src[4:]
		case attribute.ValueKindFloat64:
			val := binary.LittleEndian.Uint64(src)
			cons.Append(key, math.Float64frombits(val))
			src = src[8:]
		case attribute.ValueKindString:
			length, varintLength := binary.Uvarint(src)
			cons.Append(key, string(src[varintLength:varintLength+int(length)]))
			src = src[varintLength+int(length):]
		case attribute.ValueKindBytes:
			length, varintLength := binary.Uvarint(src)
			cons.Append(key, src[varintLength:varintLength+int(length)])
			src = src[varintLength+int(length):]
		case attribute.ValueKindErrorRaw:
			length, varintLength := binary.Uvarint(src)
			cons.Append(key, string(src[varintLength:varintLength+int(length)]))
			src = src[varintLength+int(length):]
		case attribute.ValueKindError:
			// TODO implement once beer.Error is ready.
		case attribute.ValueKindSliceBool:
			length, varintLength := binary.Uvarint(src)
			src = src[varintLength:]
			slice := make([]bool, length)
			for i := range length {
				slice[i] = src[i] != 0
			}
			cons.Append(key, slice)
			src = src[length:]
		case attribute.ValueKindSliceInt:
			length, varintLength := binary.Uvarint(src)
			src = src[varintLength:]
			slice := make([]int, length)
			for i := range length {
				v := binary.LittleEndian.Uint64(src)
				slice[i] = int(v)
				src = src[8:]
			}
			cons.Append(key, slice)
		case attribute.ValueKindSliceInt8:
			length, varintLength := binary.Uvarint(src)
			src = src[varintLength:]
			slice := make([]int8, length)
			for i := range length {
				slice[i] = int8(src[i])
			}
			cons.Append(key, slice)
			src = src[length:]
		case attribute.ValueKindSliceInt16:
			length, varintLength := binary.Uvarint(src)
			src = src[varintLength:]
			slice := make([]int16, length)
			for i := range length {
				v := binary.LittleEndian.Uint16(src)
				slice[i] = int16(v)
				src = src[2:]
			}
			cons.Append(key, slice)
		case attribute.ValueKindSliceInt32:
			length, varintLength := binary.Uvarint(src)
			src = src[varintLength:]
			slice := make([]int32, length)
			for i := range length {
				v := binary.LittleEndian.Uint32(src)
				slice[i] = int32(v)
				src = src[4:]
			}
			cons.Append(key, slice)
		case attribute.ValueKindSliceInt64:
			length, varintLength := binary.Uvarint(src)
			src = src[varintLength:]
			slice := make([]int64, length)
			for i := range length {
				v := binary.LittleEndian.Uint64(src)
				slice[i] = int64(v)
				src = src[8:]
			}
			cons.Append(key, slice)
		case attribute.ValueKindSliceUint:
			length, varuintLength := binary.Uvarint(src)
			src = src[varuintLength:]
			slice := make([]uint, length)
			for i := range length {
				v := binary.LittleEndian.Uint64(src)
				slice[i] = uint(v)
				src = src[8:]
			}
			cons.Append(key, slice)
		case attribute.ValueKindSliceUint8:
			length, varuintLength := binary.Uvarint(src)
			src = src[varuintLength:]
			slice := make([]uint8, length)
			for i := range length {
				slice[i] = src[i]
			}
			cons.Append(key, slice)
			src = src[length:]
		case attribute.ValueKindSliceUint16:
			length, varuintLength := binary.Uvarint(src)
			src = src[varuintLength:]
			slice := make([]uint16, length)
			for i := range length {
				v := binary.LittleEndian.Uint16(src)
				slice[i] = v
				src = src[2:]
			}
			cons.Append(key, slice)
		case attribute.ValueKindSliceUint32:
			length, varuintLength := binary.Uvarint(src)
			src = src[varuintLength:]
			slice := make([]uint32, length)
			for i := range length {
				v := binary.LittleEndian.Uint32(src)
				slice[i] = v
				src = src[4:]
			}
			cons.Append(key, slice)
		case attribute.ValueKindSliceUint64:
			length, varuintLength := binary.Uvarint(src)
			src = src[varuintLength:]
			slice := make([]uint64, length)
			for i := range length {
				v := binary.LittleEndian.Uint64(src)
				slice[i] = v
				src = src[8:]
			}
			cons.Append(key, slice)

		case attribute.ValueKindSliceFloat32:
			length, varfloatLength := binary.Uvarint(src)
			src = src[varfloatLength:]
			slice := make([]float32, length)
			for i := range length {
				v := binary.LittleEndian.Uint32(src)
				slice[i] = math.Float32frombits(v)
				src = src[4:]
			}
			cons.Append(key, slice)
		case attribute.ValueKindSliceFloat64:
			length, varfloatLength := binary.Uvarint(src)
			src = src[varfloatLength:]
			slice := make([]float64, length)
			for i := range length {
				v := binary.LittleEndian.Uint64(src)
				slice[i] = math.Float64frombits(v)
				src = src[8:]
			}
			cons.Append(key, slice)
		case attribute.ValueKindSliceString:
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

		case attribute.ValueKindGroup:
			length, varintLength := binary.Uvarint(src)
			src = src[varintLength:]
			src = consumeContext(cons.AppendGroup(key), src, int(length))
		}
	}

	return src
}
