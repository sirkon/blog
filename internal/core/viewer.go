package core

import (
	"encoding/binary"
	"fmt"
	"hash/crc32"
	"math"
	"time"
	"unsafe"
)

type ErrorProcessingStage int

const (
	errorProcessingStageInvalid ErrorProcessingStage = iota
	ErrorProcessingStageNew
	ErrorProcessingStageWrap
	ErrorProcessingStageContext
)

// RecordViewer to receive record elements.
type RecordViewer interface {
	Time(t time.Time)
	Level(level LoggingLevel)
	Location(file []byte, line int)
	Message([]byte)

	ContextVisitor() RecordContextVisitor
}

// RecordContextVisitor provides log record context consumption.
type RecordContextVisitor interface {
	Bool(key []byte, value bool)
	Time(key []byte, value time.Time)
	Duration(key []byte, value time.Duration)
	Int(key []byte, value int)
	Int8(key []byte, value int8)
	Int16(key []byte, value int16)
	Int32(key []byte, value int32)
	Int64(key []byte, value int64)
	Uint(key []byte, value uint)
	Uint8(key []byte, value uint8)
	Uint16(key []byte, value uint16)
	Uint32(key []byte, value uint32)
	Uint64(key []byte, value uint64)
	Float32(key []byte, value float32)
	Float64(key []byte, value float64)
	Str(key []byte, value []byte)
	Bytes(key []byte, value []byte)
	RawError(key []byte, value []byte)

	// Beware! Slice methods MUST consume iterators.

	BoolSlice(key []byte, seq []bool)
	IntSlice(key []byte, seq []int)
	Int8Slice(key []byte, seq []int8)
	Int16Slice(key []byte, seq []int16)
	Int32Slice(key []byte, seq []int32)
	Int64Slice(key []byte, seq []int64)
	UintSlice(key []byte, seq []uint)
	Uint8Slice(key []byte, seq []uint8)
	Uint16Slice(key []byte, seq []uint16)
	Uint32Slice(key []byte, seq []uint32)
	Uint64Slice(key []byte, seq []uint64)
	Float32Slice(key []byte, seq []float32)
	Float64Slice(key []byte, seq []float64)
	StrSlice(key []byte, seq [][]byte)

	EnterGroup(key []byte)
	LeaveGroup()

	EnterError(key []byte)
	EnterErrorStage(state ErrorProcessingStage, text []byte)
	LeaveErrorStage()
	LeaveError(text []byte)

	Location(file []byte, line int)

	Finish()
}

func ProcessRecord(line []byte, viewer RecordViewer) (err error) {
	//defer func() {
	//	if r := recover(); r != nil {
	//		err = errors.New(fmt.Sprint(r))
	//	}
	//}()

	if len(line) < 5 {
		return NewError("line is too short")
	}

	if line[0] != 0xFF {
		return NewError("line does not start with 0xFF")
	}
	checksum := binary.LittleEndian.Uint32(line[1:5])

	length, line, err := readUvarint(line[5:])
	if err != nil {
		return WrapError(err, "read record size")
	}

	if length != len(line) {
		return NewErrorf("record line length %d does not match the rest of data length %d", length, len(line))
	}

	actualChecksum := crc32.Checksum(line, crcTable)
	if actualChecksum != checksum {
		return NewErrorf("log checksum %x mismatches the computed checksum %x", checksum, actualChecksum)
	}

	// We have a record now
	record := line

	// Get version
	version, record := mustReadU16(record)
	if version != Version {
		return NewErrorf("record version %d does not match viewer version %d", version, Version)
	}

	// Get time
	t := time.Unix(0, int64(binary.LittleEndian.Uint64(record[:8])))
	viewer.Time(t)

	// Get level. TODO add level check.
	level := record[8]
	viewer.Level(LoggingLevel(level))

	// Get location.
	if record[9] != 0 {
		var filename []byte
		filename, record = mustReadString(record)
		length, record = mustReadUvarint(record)
		viewer.Location(filename, length)
	} else {
		record = record[10:]
	}

	// Decode Msg(string).
	var msg []byte
	msg, record = mustReadString(record)
	viewer.Message(msg)

	// Deconstruct the context.
	pd := payloadDeconstructor{}
	vis := viewer.ContextVisitor()
	pd.deconstructPayload(record, vis)
	vis.Finish()

	return nil
}

type payloadDeconstructor struct {
	someErrorStagePassed bool
	errText              [][]byte
	errTextLen           int
	errTextInProgress    bool
}

func (d *payloadDeconstructor) deconstructPayload(payload []byte, visitor RecordContextVisitor) {
	var count int
	for len(payload) > 0 {
		payload = d.deconstructNode(payload, visitor)
		count++
	}
}

func (d *payloadDeconstructor) deconstructNode(payload []byte, visitor RecordContextVisitor) []byte {
	// Read kind. TODO validate kind.
	kind := ValueKind(payload[0])
	switch kind {
	case ValueKindJustContextNode, ValueKindJustContextInheritedNode:
		if d.someErrorStagePassed {
			visitor.LeaveErrorStage()
		}
		visitor.EnterErrorStage(ErrorProcessingStageContext, nil)
		d.someErrorStagePassed = true
		return payload[1:]
	case ValueKindPhantomContextNode:
		return payload[1:]
	}

	payload = d.deconstructPayloadNode(payload[1:], kind, visitor)
	return payload
}

func (d *payloadDeconstructor) deconstructPayloadNode(
	payload []byte,
	kind ValueKind,
	visitor RecordContextVisitor,
) []byte {
	var key []byte
	if payload[0] != 0 {
		// String key.
		key, payload = mustReadString(payload)
	} else {
		// Predefined key.
		var knownIndex int
		knownIndex, payload = mustReadUvarint(payload)
		kkk := PredefinedKeys[knownIndex]
		key = unsafe.Slice(unsafe.StringData(kkk), len(kkk))
	}

	payload = d.deconstructPayloadNodeValue(payload, kind, key, visitor)
	return payload
}

func (d *payloadDeconstructor) deconstructPayloadNodeValue(
	payload []byte,
	kind ValueKind,
	key []byte,
	visitor RecordContextVisitor,
) []byte {
	switch kind {
	case ValueKindNewNode:
		if d.someErrorStagePassed {
			visitor.LeaveErrorStage()
		}
		visitor.EnterErrorStage(ErrorProcessingStageNew, key)
		if d.errTextInProgress {
			d.errText = append(d.errText, key)
			d.errTextLen += len(key)
		}
		d.someErrorStagePassed = true
	case ValueKindWrapNode:
		if d.someErrorStagePassed {
			visitor.LeaveErrorStage()
		}
		visitor.EnterErrorStage(ErrorProcessingStageWrap, key)
		if d.errTextInProgress {
			d.errText = append(d.errText, key)
			d.errTextLen += len(key)
		}
		d.someErrorStagePassed = true
	case ValueKindWrapInheritedNode:
		if d.someErrorStagePassed {
			visitor.LeaveErrorStage()
		}
		visitor.EnterErrorStage(ErrorProcessingStageWrap, key)
		if d.errTextInProgress {
			d.errText = append(d.errText, key)
			d.errTextLen += len(key)
		}
		d.someErrorStagePassed = true
	case ValueKindLocationNode:
		var line int
		line, payload = mustReadUvarint(payload)
		visitor.Location(key, line)
	case ValueKindForeignErrorText:
		if d.errTextInProgress {
			d.errText = append(d.errText, key)
			d.errTextLen += len(key)
		}
	case ValueKindForeignErrorFormat:

	case ValueKindBool:
		var v uint8
		v, payload = mustReadU8(payload)
		visitor.Bool(key, v != 0)
	case ValueKindTime:
		var v uint64
		v, payload = mustReadU64(payload)
		visitor.Time(key, time.Unix(0, int64(v)))
	case ValueKindDuration:
		var v uint64
		v, payload = mustReadU64(payload)
		visitor.Duration(key, time.Duration(v))
	case ValueKindInt:
		var v uint64
		v, payload = mustReadU64(payload)
		visitor.Int(key, int(v))
	case ValueKindInt8:
		var v uint8
		v, payload = mustReadU8(payload)
		visitor.Int8(key, int8(v))
	case ValueKindInt16:
		var v uint16
		v, payload = mustReadU16(payload)
		visitor.Int16(key, int16(v))
	case ValueKindInt32:
		var v uint32
		v, payload = mustReadU32(payload)
		visitor.Int32(key, int32(v))
	case ValueKindInt64:
		var v uint64
		v, payload = mustReadU64(payload)
		visitor.Int64(key, int64(v))
	case ValueKindUint:
		var v uint64
		v, payload = mustReadU64(payload)
		visitor.Uint(key, uint(v))
	case ValueKindUint8:
		var v uint8
		v, payload = mustReadU8(payload)
		visitor.Uint8(key, v)
	case ValueKindUint16:
		var v uint16
		v, payload = mustReadU16(payload)
		visitor.Uint16(key, v)
	case ValueKindUint32:
		var v uint32
		v, payload = mustReadU32(payload)
		visitor.Uint32(key, v)
	case ValueKindUint64:
		var v uint64
		v, payload = mustReadU64(payload)
		visitor.Uint64(key, v)
	case ValueKindFloat32:
		var v uint32
		v, payload = mustReadU32(payload)
		visitor.Float32(key, math.Float32frombits(v))
	case ValueKindFloat64:
		var v uint64
		v, payload = mustReadU64(payload)
		visitor.Float64(key, math.Float64frombits(v))
	case ValueKindString:
		var v []byte
		v, payload = mustReadString(payload)
		visitor.Str(key, v)
	case ValueKindBytes, ValueKindSliceInt8, ValueKindSliceUint8:
		var v []byte
		v, payload = mustReadString(payload)
		switch kind {
		case ValueKindBytes, ValueKindSliceUint8:
			visitor.Bytes(key, v)
		case ValueKindSliceInt8:
			visitor.Int8Slice(key, unsafe.Slice((*int8)(unsafe.Pointer(&v[0])), len(v)))
		}
	case ValueKindSliceBool:
		var length int
		length, payload = mustReadUvarint(payload)
		res := make([]bool, length)
		for i := range length {
			var v uint8
			v, payload = mustReadU8(payload)
			res[i] = v != 0
		}
		visitor.BoolSlice(key, res)
	case ValueKindSliceInt16, ValueKindSliceUint16:
		var length int
		length, payload = mustReadUvarint(payload)
		res := make([]uint16, length)
		for i := range length {
			var v uint16
			v, payload = mustReadU16(payload)
			res[i] = v
		}
		switch kind {
		case ValueKindSliceInt16:
			visitor.Int16Slice(key, unsafe.Slice((*int16)(unsafe.Pointer(&res[0])), len(res)))
		case ValueKindSliceUint16:
			visitor.Uint16Slice(key, res)
		}
	case ValueKindSliceInt32, ValueKindSliceUint32, ValueKindSliceFloat32:
		var length int
		length, payload = mustReadUvarint(payload)
		res := make([]uint32, length)
		for i := range length {
			var v uint32
			v, payload = mustReadU32(payload)
			res[i] = v
		}
		switch kind {
		case ValueKindSliceInt32:
			visitor.Int32Slice(key, unsafe.Slice((*int32)(unsafe.Pointer(&res[0])), len(res)))
		case ValueKindSliceFloat32:
			visitor.Float32Slice(key, unsafe.Slice((*float32)(unsafe.Pointer(&res[0])), len(res)))
		case ValueKindSliceUint32:
			visitor.Uint32Slice(key, res)
		}
	case ValueKindSliceInt64, ValueKindSliceUint64, ValueKindSliceFloat64, ValueKindSliceInt, ValueKindSliceUint:
		var length int
		length, payload = mustReadUvarint(payload)
		res := make([]uint64, length)
		for i := range length {
			var v uint64
			v, payload = mustReadU64(payload)
			res[i] = v
		}
		switch kind {
		case ValueKindSliceInt:
			visitor.IntSlice(key, unsafe.Slice((*int)(unsafe.Pointer(&res[0])), len(res)))
		case ValueKindSliceUint:
			visitor.UintSlice(key, unsafe.Slice((*uint)(unsafe.Pointer(&res[0])), len(res)))
		case ValueKindSliceInt64:
			visitor.Int64Slice(key, unsafe.Slice((*int64)(unsafe.Pointer(&res[0])), len(res)))
		case ValueKindSliceFloat64:
			visitor.Float64Slice(key, unsafe.Slice((*float64)(unsafe.Pointer(&res[0])), len(res)))
		case ValueKindSliceUint64:
			visitor.Uint64Slice(key, res)
		}
	case ValueKindSliceString:
		var length int
		length, payload = mustReadUvarint(payload)
		res := make([][]byte, length)
		for i := range length {
			var v []byte
			v, payload = mustReadString(payload)
			res[i] = v
		}
		visitor.StrSlice(key, res)
	case ValueKindGroup:
		var length int
		length, payload = mustReadUvarint(payload)
		visitor.EnterGroup(key)
		for range length {
			payload = d.deconstructNode(payload, visitor)
		}
		visitor.LeaveGroup()
	case ValueKindError:
		d.someErrorStagePassed = false
		var length int
		length, payload = mustReadUvarint(payload)
		d.someErrorStagePassed = false
		visitor.EnterError(key)
		d.errText = d.errText[:0]
		d.errTextLen = 0
		d.errTextInProgress = true
		d.deconstructPayload(payload[:length], visitor)

		buf := make([]byte, 0, d.errTextLen+(len(d.errText)-1)*2)
		for i := len(d.errText) - 1; i >= 0; i-- {
			buf = append(buf, d.errText[i]...)
			if i > 0 {
				buf = append(buf, ':', ' ')
			}
		}
		if d.someErrorStagePassed {
			visitor.LeaveErrorStage()
		}
		visitor.LeaveError(buf)

		payload = payload[length:]
	case ValueKindErrorEmbed:
		var errorText []byte
		errorText, payload = mustReadString(payload)
		var length int
		length, payload = mustReadUvarint(payload)
		d.someErrorStagePassed = false
		visitor.EnterError(key)
		d.errText = d.errText[:0]
		d.errTextLen = 0
		d.errTextInProgress = false
		d.deconstructPayload(payload[:length], visitor)
		if d.someErrorStagePassed {
			visitor.LeaveErrorStage()
		}
		visitor.LeaveError(errorText)
		payload = payload[length:]
	case ValueKindErrorRaw:
		var value []byte
		value, payload = mustReadString(payload)
		visitor.RawError(key, value)
	default:
		panic(fmt.Errorf("unknown value kind %s", kind))
	}

	return payload
}

func readUvarint(src []byte) (int, []byte, error) {
	length, uvarintLength := binary.Uvarint(src)
	if uvarintLength <= 0 {
		if uvarintLength == 0 {
			return 0, nil, NewError("incomplete source")
		}
		return 0, nil, NewError("computing value is out of range")
	}

	return int(length), src[uvarintLength:], nil
}

func mustReadUvarint(src []byte) (int, []byte) {
	length, uvarintLength := binary.Uvarint(src)
	if uvarintLength <= 0 {
		if uvarintLength == 0 {
			panic("broken uvarint length")
		}
		panic("uvarint length is out of range")
	}

	return int(length), src[uvarintLength:]
}

func mustReadString(src []byte) (str []byte, rest []byte) {
	length, srcn := mustReadUvarint(src)
	return srcn[:length], srcn[length:]
}

func mustReadU8(s []byte) (uint8, []byte) {
	return s[0], s[1:]
}

func mustReadU16(s []byte) (uint16, []byte) {
	return binary.LittleEndian.Uint16(s[:2]), s[2:]
}

func mustReadU32(s []byte) (uint32, []byte) {
	return binary.LittleEndian.Uint32(s[:4]), s[4:]
}

func mustReadU64(s []byte) (uint64, []byte) {
	return binary.LittleEndian.Uint64(s[:8]), s[8:]
}
