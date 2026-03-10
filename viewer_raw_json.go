package blog

import (
	"encoding/base64"
	"io"
	"strconv"
	"time"
	"unsafe"

	"github.com/sirkon/blog/internal/core"
)

type RawJSONWriter struct {
	w    io.Writer
	view *JSONRecordView
}

func NewRawJSONWriter(w io.Writer) *RawJSONWriter {
	return &RawJSONWriter{
		w:    w,
		view: &JSONRecordView{},
	}
}

func (g *RawJSONWriter) Write(p []byte) (n int, err error) {
	g.view.Reset()
	if err := core.ProcessRecord(p, g.view); err != nil {
		return 0, core.WrapError(err, "process record")
	}
	g.view.data = append(g.view.data, '}')
	n, err = g.w.Write(append(g.view.data, '\n'))
	if err != nil {
		return n, core.WrapError(err, "write processed arena")
	}

	return n, nil
}

type JSONRecordView struct {
	errPos []int

	data []byte
}

func (v *JSONRecordView) Reset() {
	v.errPos = v.errPos[:0]
	v.data = v.data[:0]
	v.data = append(v.data, '{')
}

func (v *JSONRecordView) Time(t time.Time) {
	v.data = append(v.data, `"time":"`...)
	v.data = append(v.data, t.Format(time.RFC3339Nano)...)
	v.data = append(v.data, '"')
}

func (v *JSONRecordView) Level(level core.LoggingLevel) {
	v.data = append(v.data, `,"level":"`...)
	v.data = append(v.data, level.String()...)
	v.data = append(v.data, '"')
}

func (v *JSONRecordView) Location(file []byte, line int) {
	v.data = append(v.data, `,"location":`...)
	v.data = strconv.AppendQuote(v.data, unsafe.String(unsafe.SliceData(file), len(file)))
	v.data = v.data[:len(v.data)-1]
	v.data = append(v.data, ':')
	v.data = strconv.AppendInt(v.data, int64(line), 10)
	v.data = append(v.data, '"')
}

func (v *JSONRecordView) Message(bytes []byte) {
	v.data = append(v.data, `,"message":`...)
	v.data = strconv.AppendQuote(v.data, unsafe.String(unsafe.SliceData(bytes), len(bytes)))
}

func (v *JSONRecordView) ContextVisitor() core.RecordContextVisitor {
	return &jsonContextView{
		rec:  v,
		data: v.data,
		old:  true,
	}
}

type jsonContextView struct {
	old   bool
	rec   *JSONRecordView
	data  []byte
	inErr bool
	text  [][]byte
}

func (c *jsonContextView) Finish() {
	c.rec.data = c.data
}

func (c *jsonContextView) pushKey(key []byte) {
	if c.old {
		c.data = append(c.data, ',')
	}
	c.data = strconv.AppendQuote(c.data, unsafe.String(unsafe.SliceData(key), len(key)))
	c.data = append(c.data, ':')
	c.old = true
}

func (c *jsonContextView) pushKeyStr(key string) {
	if c.old {
		c.data = append(c.data, ',')
	}
	c.data = strconv.AppendQuote(c.data, key)
	c.data = append(c.data, ':')
	c.old = true
}

func (c *jsonContextView) pushBytes(key []byte, data []byte) {
	c.pushKey(key)
	c.data = append(c.data, data...)
}

func (c *jsonContextView) pushStr(key []byte, data string) {
	c.pushKey(key)
	c.data = append(c.data, data...)
}

func (c *jsonContextView) pushQuoteBytes(key []byte, data []byte) {
	c.pushKey(key)
	c.data = strconv.AppendQuote(c.data, unsafe.String(unsafe.SliceData(data), len(data)))
}

func (c *jsonContextView) pushQuoteStr(key []byte, data string) {
	c.pushKey(key)
	c.data = strconv.AppendQuote(c.data, data)
}

func (c *jsonContextView) Bool(key []byte, value bool) {
	if value {
		c.pushStr(key, "true")
	} else {
		c.pushStr(key, "false")
	}
}

func (c *jsonContextView) Time(key []byte, value time.Time) {
	c.pushQuoteStr(key, value.Format(time.RFC3339Nano))
}

func (c *jsonContextView) Duration(key []byte, value time.Duration) {
	c.pushQuoteStr(key, value.String())
}

func (c *jsonContextView) Int(key []byte, value int) {
	c.pushStr(key, strconv.Itoa(value))
}

func (c *jsonContextView) Int8(key []byte, value int8) {
	c.pushStr(key, strconv.FormatInt(int64(value), 10))
}

func (c *jsonContextView) Int16(key []byte, value int16) {
	c.pushStr(key, strconv.FormatInt(int64(value), 10))
}

func (c *jsonContextView) Int32(key []byte, value int32) {
	c.pushStr(key, strconv.FormatInt(int64(value), 10))
}

func (c *jsonContextView) Int64(key []byte, value int64) {
	c.pushStr(key, strconv.FormatInt(value, 10))
}

func (c *jsonContextView) Uint(key []byte, value uint) {
	c.pushStr(key, strconv.FormatUint(uint64(value), 10))
}

func (c *jsonContextView) Uint8(key []byte, value uint8) {
	c.pushStr(key, strconv.FormatUint(uint64(value), 10))
}

func (c *jsonContextView) Uint16(key []byte, value uint16) {
	c.pushStr(key, strconv.FormatUint(uint64(value), 10))
}

func (c *jsonContextView) Uint32(key []byte, value uint32) {
	c.pushStr(key, strconv.FormatUint(uint64(value), 10))
}

func (c *jsonContextView) Uint64(key []byte, value uint64) {
	c.pushStr(key, strconv.FormatUint(value, 10))
}

func (c *jsonContextView) Float32(key []byte, value float32) {
	c.pushStr(key, strconv.FormatFloat(float64(value), 'g', -1, 32))
}

func (c *jsonContextView) Float64(key []byte, value float64) {
	c.pushStr(key, strconv.FormatFloat(value, 'g', -1, 64))
}

func (c *jsonContextView) Str(key []byte, value []byte) {
	c.pushQuoteBytes(key, value)
}

func (c *jsonContextView) Bytes(key []byte, value []byte) {
	var length = (len(value) + 2) * 4 / 3
	c.pushQuoteBytes(key, base64.RawStdEncoding.AppendEncode(make([]byte, 0, length), value))
}

func (c *jsonContextView) RawError(key []byte, value []byte) {
	c.rec.errPos = append(c.rec.errPos, len(c.data))
	c.pushQuoteBytes(key, value)
}

func (c *jsonContextView) BoolSlice(key []byte, seq []bool) {
	c.pushKey(key)
	c.data = append(c.data, '[')
	for i, b := range seq {
		if i > 0 {
			c.data = append(c.data, ',')
		}
		if b {
			c.data = append(c.data, "true"...)
		} else {
			c.data = append(c.data, "false"...)
		}
	}
	c.data = append(c.data, ']')
}

func (c *jsonContextView) IntSlice(key []byte, seq []int) {
	c.pushKey(key)
	c.data = append(c.data, '[')
	for i, b := range seq {
		if i > 0 {
			c.data = append(c.data, ',')
		}
		c.data = append(c.data, strconv.Itoa(b)...)
	}
	c.data = append(c.data, ']')
}

func (c *jsonContextView) Int8Slice(key []byte, seq []int8) {
	c.pushKey(key)
	c.data = append(c.data, '[')
	for i, b := range seq {
		if i > 0 {
			c.data = append(c.data, ',')
		}
		c.data = append(c.data, strconv.Itoa(int(b))...)
	}
	c.data = append(c.data, ']')
}

func (c *jsonContextView) Int16Slice(key []byte, seq []int16) {
	c.pushKey(key)
	c.data = append(c.data, '[')
	for i, b := range seq {
		if i > 0 {
			c.data = append(c.data, ',')
		}
		c.data = append(c.data, strconv.Itoa(int(b))...)
	}
	c.data = append(c.data, ']')
}

func (c *jsonContextView) Int32Slice(key []byte, seq []int32) {
	c.pushKey(key)
	c.data = append(c.data, '[')
	for i, b := range seq {
		if i > 0 {
			c.data = append(c.data, ',')
		}
		c.data = append(c.data, strconv.Itoa(int(b))...)
	}
	c.data = append(c.data, ']')
}

func (c *jsonContextView) Int64Slice(key []byte, seq []int64) {
	c.pushKey(key)
	c.data = append(c.data, '[')
	for i, b := range seq {
		if i > 0 {
			c.data = append(c.data, ',')
		}
		c.data = append(c.data, strconv.FormatInt(b, 10)...)
	}
	c.data = append(c.data, ']')
}

func (c *jsonContextView) UintSlice(key []byte, seq []uint) {
	c.pushKey(key)
	c.data = append(c.data, '[')
	for i, b := range seq {
		if i > 0 {
			c.data = append(c.data, ',')
		}
		c.data = append(c.data, strconv.FormatUint(uint64(b), 10)...)
	}
	c.data = append(c.data, ']')
}

func (c *jsonContextView) Uint8Slice(key []byte, seq []uint8) {
	c.pushKey(key)
	c.data = append(c.data, '[')
	for i, b := range seq {
		if i > 0 {
			c.data = append(c.data, ',')
		}
		c.data = append(c.data, strconv.FormatUint(uint64(b), 10)...)
	}
	c.data = append(c.data, ']')
}

func (c *jsonContextView) Uint16Slice(key []byte, seq []uint16) {
	c.pushKey(key)
	c.data = append(c.data, '[')
	for i, b := range seq {
		if i > 0 {
			c.data = append(c.data, ',')
		}
		c.data = append(c.data, strconv.FormatUint(uint64(b), 10)...)
	}
	c.data = append(c.data, ']')
}

func (c *jsonContextView) Uint32Slice(key []byte, seq []uint32) {
	c.pushKey(key)
	c.data = append(c.data, '[')
	for i, b := range seq {
		if i > 0 {
			c.data = append(c.data, ',')
		}
		c.data = append(c.data, strconv.FormatUint(uint64(b), 10)...)
	}
	c.data = append(c.data, ']')
}

func (c *jsonContextView) Uint64Slice(key []byte, seq []uint64) {
	c.pushKey(key)
	c.data = append(c.data, '[')
	for i, b := range seq {
		if i > 0 {
			c.data = append(c.data, ',')
		}
		c.data = append(c.data, strconv.FormatUint(b, 10)...)
	}
	c.data = append(c.data, ']')
}

func (c *jsonContextView) Float32Slice(key []byte, seq []float32) {
	c.pushKey(key)
	c.data = append(c.data, '[')
	for i, b := range seq {
		if i > 0 {
			c.data = append(c.data, ',')
		}
		c.data = append(c.data, strconv.FormatFloat(float64(b), 'g', -1, 64)...)
	}
	c.data = append(c.data, ']')
}

func (c *jsonContextView) Float64Slice(key []byte, seq []float64) {
	c.pushKey(key)
	c.data = append(c.data, '[')
	for i, b := range seq {
		if i > 0 {
			c.data = append(c.data, ',')
		}
		c.data = append(c.data, strconv.FormatFloat(b, 'g', -1, 64)...)
	}
	c.data = append(c.data, ']')
}

func (c *jsonContextView) StrSlice(key []byte, seq [][]byte) {
	c.pushKey(key)
	c.data = append(c.data, '[')
	for i, b := range seq {
		if i > 0 {
			c.data = append(c.data, ',')
		}
		c.data = append(c.data, '"')
		c.data = append(c.data, string(b)...)
		c.data = append(c.data, '"')
	}
	c.data = append(c.data, ']')
}

func (c *jsonContextView) EnterGroup(key []byte) {
	c.pushKey(key)
	c.data = append(c.data, '{')
	c.old = false
}

func (c *jsonContextView) LeaveGroup() {
	c.data = append(c.data, '}')
	c.old = true
}

func (c *jsonContextView) EnterError(key []byte) {
	c.rec.errPos = append(c.rec.errPos, len(c.data))
	c.pushKey(key)
	c.data = append(c.data, '{')
	c.old = false
	c.inErr = false
}

func (c *jsonContextView) EnterErrorStage(state core.ErrorProcessingStage, text []byte) {
	if !c.inErr {
		c.pushKeyStr("@context")
		c.data = append(c.data, '{')
		c.inErr = true
		c.old = false
	}

	switch state {
	case core.ErrorProcessingStageNew:
		c.pushKeyStr("NEW: " + string(text))
	case core.ErrorProcessingStageWrap:
		c.pushKeyStr("WRAP: " + string(text))
	case core.ErrorProcessingStageContext:
		c.pushKeyStr("CTX")
	}
	c.data = append(c.data, '{')
	c.old = false
}

func (c *jsonContextView) LeaveErrorStage() {
	c.data = append(c.data, '}')
	c.old = true
}

var textContextKey = []byte("@text")

func (c *jsonContextView) LeaveError(text []byte) {
	c.data = append(c.data, '}') // Close @context.
	c.pushQuoteBytes(textContextKey, text)
	c.data = append(c.data, '}')
	c.old = true
}

func (c *jsonContextView) ErrorStageLocation(file []byte, line int) {
	c.pushKeyStr("@location")
	c.data = strconv.AppendQuote(c.data, unsafe.String(unsafe.SliceData(file), len(file)))
	c.data = c.data[:len(c.data)-1]
	c.data = append(c.data, ':')
	c.data = strconv.AppendInt(c.data, int64(line), 10)
	c.data = append(c.data, '"')
}
