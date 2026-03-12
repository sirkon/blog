package blog

import (
	"go/token"
	"strconv"
	"time"
	"unsafe"

	"github.com/sirkon/blog/internal/core"
)

type packedDeconstruct struct {
	time  time.Time
	level core.LoggingLevel
	loc   token.Position
	msg   []byte

	tree *packedTree
	ctx  *packedContextDeconstruct
}

func (p *packedDeconstruct) Time(t time.Time) {
	p.time = t
}

func (p *packedDeconstruct) Level(level core.LoggingLevel) {
	p.level = level
}

func (p *packedDeconstruct) Location(file []byte, line int) {
	p.loc = token.Position{
		Filename: unsafe.String(unsafe.SliceData(file), len(file)),
		Line:     line,
	}
}

func (p *packedDeconstruct) Message(bytes []byte) {
	p.msg = bytes
}

func (p *packedDeconstruct) ContextVisitor() core.RecordContextVisitor {
	return p.ctx
}

type packedContextDeconstruct struct {
	errors   []int
	prev     int
	stack    []int
	tree     *packedTree
	stageBuf []byte
}

func (p *packedContextDeconstruct) Reset() {
	p.errors = p.errors[:0]
	p.stack = p.stack[:0]
	p.prev = -1
}

func (p *packedContextDeconstruct) Bool(key []byte, value bool) {
	p.prev = p.tree.AddBool(p.prev, key, value)
}

func (p *packedContextDeconstruct) Time(key []byte, value time.Time) {
	p.prev = p.tree.AddTime(p.prev, key, value)
}

func (p *packedContextDeconstruct) Duration(key []byte, value time.Duration) {
	p.prev = p.tree.AddDuration(p.prev, key, value)
}

func (p *packedContextDeconstruct) Int(key []byte, value int) {
	p.prev = p.tree.AddInt(p.prev, key, int64(value))
}

func (p *packedContextDeconstruct) Int8(key []byte, value int8) {
	p.prev = p.tree.AddInt(p.prev, key, int64(value))
}

func (p *packedContextDeconstruct) Int16(key []byte, value int16) {
	p.prev = p.tree.AddInt(p.prev, key, int64(value))
}

func (p *packedContextDeconstruct) Int32(key []byte, value int32) {
	p.prev = p.tree.AddInt(p.prev, key, int64(value))
}

func (p *packedContextDeconstruct) Int64(key []byte, value int64) {
	p.prev = p.tree.AddInt(p.prev, key, int64(value))
}

func (p *packedContextDeconstruct) Uint(key []byte, value uint) {
	p.prev = p.tree.AddUint(p.prev, key, uint64(value))
}

func (p *packedContextDeconstruct) Uint8(key []byte, value uint8) {
	p.prev = p.tree.AddUint(p.prev, key, uint64(value))
}

func (p *packedContextDeconstruct) Uint16(key []byte, value uint16) {
	p.prev = p.tree.AddUint(p.prev, key, uint64(value))
}

func (p *packedContextDeconstruct) Uint32(key []byte, value uint32) {
	p.prev = p.tree.AddUint(p.prev, key, uint64(value))
}

func (p *packedContextDeconstruct) Uint64(key []byte, value uint64) {
	p.prev = p.tree.AddUint(p.prev, key, value)
}

func (p *packedContextDeconstruct) Float32(key []byte, value float32) {
	p.prev = p.tree.AddFloat(p.prev, key, float64(value))
}

func (p *packedContextDeconstruct) Float64(key []byte, value float64) {
	p.prev = p.tree.AddFloat(p.prev, key, value)
}

func (p *packedContextDeconstruct) Str(key []byte, value []byte) {
	p.prev = p.tree.AddString(p.prev, key, value)
}

func (p *packedContextDeconstruct) Bytes(key []byte, value []byte) {
	p.prev = p.tree.AddBytes(p.prev, key, value)
}

func (p *packedContextDeconstruct) RawError(key []byte, value []byte) {
	p.prev = p.tree.AddString(p.prev, key, value)
	p.errors = append(p.errors, p.prev)
}

func (p *packedContextDeconstruct) BoolSlice(key []byte, seq []bool) {
	p.prev = p.tree.AddBoolArray(p.prev, key, seq)
}

func (p *packedContextDeconstruct) IntSlice(key []byte, seq []int) {
	p.prev = p.tree.AddIntSlice(p.prev, key, seq)
}

func (p *packedContextDeconstruct) Int8Slice(key []byte, seq []int8) {
	p.prev = p.tree.AddInt8Slice(p.prev, key, seq)
}

func (p *packedContextDeconstruct) Int16Slice(key []byte, seq []int16) {
	p.prev = p.tree.AddInt16Slice(p.prev, key, seq)
}

func (p *packedContextDeconstruct) Int32Slice(key []byte, seq []int32) {
	p.prev = p.tree.AddInt32Slice(p.prev, key, seq)
}

func (p *packedContextDeconstruct) Int64Slice(key []byte, seq []int64) {
	p.prev = p.tree.AddInt64Slice(p.prev, key, seq)
}

func (p *packedContextDeconstruct) UintSlice(key []byte, seq []uint) {
	p.prev = p.tree.AddUintSlice(p.prev, key, seq)
}

func (p *packedContextDeconstruct) Uint8Slice(key []byte, seq []uint8) {
	p.prev = p.tree.AddUint8Slice(p.prev, key, seq)
}

func (p *packedContextDeconstruct) Uint16Slice(key []byte, seq []uint16) {
	p.prev = p.tree.AddUint16Slice(p.prev, key, seq)
}

func (p *packedContextDeconstruct) Uint32Slice(key []byte, seq []uint32) {
	p.prev = p.tree.AddUint32Slice(p.prev, key, seq)
}

func (p *packedContextDeconstruct) Uint64Slice(key []byte, seq []uint64) {
	p.prev = p.tree.AddUint64Slice(p.prev, key, seq)
}

func (p *packedContextDeconstruct) Float32Slice(key []byte, seq []float32) {
	p.prev = p.tree.AddFloat32Slice(p.prev, key, seq)
}

func (p *packedContextDeconstruct) Float64Slice(key []byte, seq []float64) {
	p.prev = p.tree.AddFloat64Slice(p.prev, key, seq)
}

func (p *packedContextDeconstruct) StrSlice(key []byte, seq [][]byte) {
	p.prev = p.tree.AddStringSlice(p.prev, key, seq)
}

func (p *packedContextDeconstruct) EnterGroup(key []byte) {
	p.prev = p.tree.AddObjectRoot(p.prev, key)
	p.stack = append(p.stack, p.prev)
}

func (p *packedContextDeconstruct) LeaveGroup() {
	p.tree.CloseObjectRoot(p.prev)
	p.prev = p.stack[len(p.stack)-1]
	p.stack = p.stack[:len(p.stack)-1]
}

func (p *packedContextDeconstruct) EnterError(key []byte) {
	p.prev = p.tree.AddObjectRoot(p.prev, key)
	p.stack = append(p.stack, p.prev)
	p.errors = append(p.errors, p.prev)
	ctxKey := "@context"
	p.prev = p.tree.AddObjectRoot(p.prev, unsafe.Slice(unsafe.StringData(ctxKey), len(ctxKey)))
	p.stack = append(p.stack, p.prev)
}

func (p *packedContextDeconstruct) EnterErrorStage(state core.ErrorProcessingStage, text []byte) {
	p.stageBuf = p.stageBuf[:0]
	switch state {
	case core.ErrorProcessingStageNew:
		p.stageBuf = append(p.stageBuf, "NEW: "...)
		p.stageBuf = append(p.stageBuf, text...)
	case core.ErrorProcessingStageWrap:
		p.stageBuf = append(p.stageBuf, "WRAP: "...)
		p.stageBuf = append(p.stageBuf, text...)
	case core.ErrorProcessingStageContext:
		p.stageBuf = append(p.stageBuf, "CTX"...)
	}
	p.prev = p.tree.AddObjectRoot(p.prev, p.stageBuf)
	p.stack = append(p.stack, p.prev)
}

func (p *packedContextDeconstruct) ErrorStageLocation(file []byte, line int) {
	p.stageBuf = p.stageBuf[:0]
	p.stageBuf = append(p.stageBuf, file...)
	p.stageBuf = append(p.stageBuf, ':')
	p.stageBuf = strconv.AppendInt(p.stageBuf, int64(line), 10)
	locText := "@location"
	p.prev = p.tree.AddString(
		p.prev,
		unsafe.Slice(unsafe.StringData(locText), len(locText)),
		p.stageBuf,
	)
}

func (p *packedContextDeconstruct) LeaveErrorStage() {
	p.tree.CloseObjectRoot(p.prev)
	p.prev = p.stack[len(p.stack)-1]
	p.stack = p.stack[:len(p.stack)-1]
}

func (p *packedContextDeconstruct) LeaveError(text []byte) {
	// Close context
	p.prev = p.stack[len(p.stack)-1]
	p.stack = p.stack[:len(p.stack)-1]

	// Add @text
	textText := "@text"
	p.prev = p.tree.AddString(
		p.prev,
		unsafe.Slice(unsafe.StringData(textText), len(textText)),
		text,
	)
	p.errors = append(p.errors, p.prev)

	// Close error
	p.prev = p.stack[len(p.stack)-1]
	p.stack = p.stack[:len(p.stack)-1]
}

func (p *packedContextDeconstruct) Finish() {}
