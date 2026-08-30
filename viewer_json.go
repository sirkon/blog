package blog

import (
	"bufio"
	"bytes"
	"compress/gzip"
	"encoding/base64"
	"fmt"
	"go/token"
	"io"
	"math"
	"os"
	"strconv"
	"sync"
	"time"
	"unsafe"

	"github.com/sirkon/blog/internal/core"
)

type JSONWriter struct {
	lock sync.Mutex

	w    io.Writer
	view *packedDeconstruct
	buf  []byte
}

func NewJSONWriter(w io.Writer) *JSONWriter {
	tree := &packedTree{
		ctrl: make([]byte, prettyViewNodeSize*128),
		data: make([]byte, 0, 2048),
	}
	ctx := &packedContextDeconstruct{
		tree: tree,
	}
	return &JSONWriter{
		w: w,
		view: &packedDeconstruct{
			tree: tree,
			ctx:  ctx,
		},
	}
}

func (g *JSONWriter) Write(p []byte) (n int, err error) {
	g.lock.Lock()
	defer g.lock.Unlock()

	g.view.loc = token.Position{}
	g.view.tree.Reset()
	g.view.ctx.Reset()
	g.buf = g.buf[:0]

	if err := core.ProcessRecord(p, g.view); err != nil {
		return 0, core.WrapError(err, "process record")
	}

	if g.view.level != core.LoggingLevelPanic {
		g.appendJSONLine(g.view.msg)
	} else {
		reader, err := gzip.NewReader(bytes.NewReader(g.view.msg))
		if err != nil {
			g.appendJSONLine([]byte(err.Error()))
		} else {
			scanner := bufio.NewScanner(reader)
			for scanner.Scan() {
				g.appendJSONLine(scanner.Bytes())
			}
		}
	}

	if _, err := g.w.Write(g.buf); err != nil {
		_, _ = fmt.Fprintln(os.Stderr, "failed to write buffer:", err)
	}

	return len(p), nil
}

// appendJSONLine appends the whole line covering the current record with the given message.
func (g *JSONWriter) appendJSONLine(msg []byte) {
	g.buf = append(g.buf, '{')
	g.buf = append(g.buf, '"', 't', 'i', 'm', 'e', '"', ':')
	g.buf = strconv.AppendQuote(g.buf, g.view.time.Format(time.RFC3339Nano))
	switch g.view.level {
	case core.LoggingLevelTrace:
		g.appendMeta(`"level"`, "TRACE")
	case core.LoggingLevelDebug:
		g.appendMeta(`"level"`, "DEBUG")
	case core.LoggingLevelInfo:
		g.appendMeta(`"level"`, "INFO")
	case core.LoggingLevelWarning:
		g.appendMeta(`"level"`, "WARNING")
	case core.LoggingLevelError:
		g.appendMeta(`"level"`, "ERROR")
	case core.LoggingLevelPanic:
		g.appendMeta(`"level"`, "PANIC")
	default:
		g.appendMeta(`"level"`, fmt.Sprintf("INVALID(%d)", g.view.level))
	}
	if g.view.loc.IsValid() {
		g.buf = append(g.buf, ',', '"', 'l', 'o', 'c', '"', ':', '{', '"', 'f', 'i', 'l', 'e', '"', ':')
		g.buf = strconv.AppendQuote(g.buf, g.view.loc.Filename)
		g.buf = append(g.buf, ',', '"', 'l', 'i', 'n', 'e', '"', ':')
		g.buf = strconv.AppendInt(g.buf, int64(g.view.loc.Line), 10)
		g.buf = append(g.buf, '}')
	}
	g.appendMessage(msg)
	g.walkJSON()
	g.buf = append(g.buf, '\n')
}

func (g *JSONWriter) appendMeta(key string, value string) {
	g.buf = append(g.buf, ',')
	g.buf = append(g.buf, key...)
	g.buf = append(g.buf, ':')
	g.buf = strconv.AppendQuote(g.buf, value)
}

func (g *JSONWriter) appendMessage(msg []byte) {
	g.buf = append(g.buf, ',', '"', 'm', 's', 'g', '"', ':')
	g.buf = strconv.AppendQuote(g.buf, string(msg))
}

// walkJSON appends the context tree as JSON object fields. The message is always
// rendered before so the first tree field goes with the leading comma. Nested
// object roots flush the comma flag as they open their own scope.
func (g *JSONWriter) walkJSON() {
	var pos int
	stack := make([]int, 0, 4)
	ctrl := g.view.tree.ctrl
	t := g.view.tree
	old := true

	if t.clen == 0 {
		g.buf = append(g.buf, '}')
		return
	}


mainLoop:
	for {
		node := (*prettyViewNode)(unsafe.Add(unsafe.Pointer(unsafe.SliceData(ctrl)), pos))

		// Draw a key
		key := t.unpackKey(node)
		if old {
			g.buf = append(g.buf, ',')
		}
		old = true
		g.buf = strconv.AppendQuote(g.buf, key)
		g.buf = append(g.buf, ':')

		// Switch over variants of values.
		switch node.kind & 0x1F {
		case prettyViewKindRoot:
			// TODO implement passing.
			g.buf = append(g.buf, '{')
			if node.misc == math.MaxUint32 {
				g.buf = append(g.buf, '}')
				break
			}
			old = false
			stack = append(stack, pos)
			pos = int(node.misc)
			continue
		case prettyViewKindValueBool:
			if node.kind>>8 != 0 {
				g.buf = append(g.buf, "true"...)
			} else {
				g.buf = append(g.buf, "false"...)
			}
		case prettyViewKindValueTime:
			g.buf = append(g.buf, '"')
			g.buf = append(
				g.buf,
				time.Unix(0, int64(unpackFullNum(node.kind, node.misc))).Format(time.RFC3339Nano)...,
			)
			g.buf = append(g.buf, '"')
		case prettyViewKindValueDuration:
			g.buf = append(g.buf, '"')
			g.buf = append(g.buf, time.Duration(unpackFullNum(node.kind, node.misc)).String()...)
			g.buf = append(g.buf, '"')
		case prettyViewKindValueInt:
			g.buf = strconv.AppendInt(g.buf, int64(unpackFullNum(node.kind, node.misc)), 10)
		case prettyViewKindValueUint:
			g.buf = strconv.AppendUint(g.buf, unpackFullNum(node.kind, node.misc), 10)
		case prettyViewKindValueFloat:
			value := math.Float64frombits(unpackFullNum(node.kind, node.misc))
			g.buf = strconv.AppendFloat(g.buf, value, 'g', -1, 64)
		case prettyViewKindValueString:
			off := node.kind >> 32
			value := unsafe.String(
				(*byte)(unsafe.Add(unsafe.Pointer(unsafe.SliceData(t.data)), off)),
				node.misc,
			)
			g.buf = strconv.AppendQuote(g.buf, value)
		case prettyViewKindValueStringShort:
			var shortPlace uint64
			var longPlace [16]byte
			value := unpackShortStringValue(node, &shortPlace, longPlace)
			g.buf = strconv.AppendQuote(g.buf, unsafe.String(unsafe.SliceData(value), len(value)))
		case prettyViewKindValueByteSlice:
			off := node.kind >> 32
			value := unsafe.Slice(
				(*byte)(unsafe.Add(unsafe.Pointer(unsafe.SliceData(t.data)), off)),
				node.misc,
			)
			g.buf = append(g.buf, '"')
			g.buf = base64.URLEncoding.AppendEncode(g.buf, value)
			g.buf = append(g.buf, '"')
		case prettyViewKindValueByteSliceShort:
			var shortPlace uint64
			var longPlace [16]byte
			value := unpackShortStringValue(node, &shortPlace, longPlace)
			g.buf = append(g.buf, '"')
			g.buf = base64.URLEncoding.AppendEncode(g.buf, value)
			g.buf = append(g.buf, '"')
		case prettyViewKindValueBoolSlice:
			g.unpackBoolsJSON(node)
		case prettyViewKindValueBoolSliceShort:
			g.buf = append(g.buf, '[')
			length := node.kind << 52 >> 57
			if length == 0 {
				g.buf = append(g.buf, ']')
				break
			}
			part1 := node.kind >> 12
			part2 := node.misc
			if length <= 52 {
				for range length {
					if part1&0x01 != 0 {
						g.buf = append(g.buf, "true,"...)
					} else {
						g.buf = append(g.buf, "false,"...)
					}
					part1 >>= 1
				}
			} else {
				for range 52 {
					if part1&0x01 != 0 {
						g.buf = append(g.buf, "true,"...)
					} else {
						g.buf = append(g.buf, "false,"...)
					}
					part1 >>= 1
				}
				length -= 52
				for range length {
					if part2&0x01 != 0 {
						g.buf = append(g.buf, "true,"...)
					} else {
						g.buf = append(g.buf, "false,"...)
					}
					part2 >>= 1
				}
			}
			g.buf = g.buf[:len(g.buf)-1]
			g.buf = append(g.buf, ']')
		case prettyViewKindValueIntSlice:
			off := node.kind >> 32
			src := unsafe.Slice((*int)(unsafe.Add(unsafe.Pointer(unsafe.SliceData(t.data)), off)), node.misc)
			g.buf = append(g.buf, '[')
			for i, v := range src {
				if i > 0 {
					g.buf = append(g.buf, ',')
				}
				g.buf = strconv.AppendInt(g.buf, int64(v), 10)
			}
			g.buf = append(g.buf, ']')
		case prettyViewKindValueInt8Slice:
			off := node.kind >> 32
			src := unsafe.Slice((*int8)(unsafe.Add(unsafe.Pointer(unsafe.SliceData(t.data)), off)), node.misc)
			g.buf = append(g.buf, '[')
			for i, v := range src {
				if i > 0 {
					g.buf = append(g.buf, ',')
				}
				g.buf = strconv.AppendInt(g.buf, int64(v), 10)
			}
			g.buf = append(g.buf, ']')
		case prettyViewKindValueInt16Slice:
			off := node.kind >> 32
			src := unsafe.Slice((*int16)(unsafe.Add(unsafe.Pointer(unsafe.SliceData(t.data)), off)), node.misc)
			g.buf = append(g.buf, '[')
			for i, v := range src {
				if i > 0 {
					g.buf = append(g.buf, ',')
				}
				g.buf = strconv.AppendInt(g.buf, int64(v), 10)
			}
			g.buf = append(g.buf, ']')
		case prettyViewKindValueInt32Slice:
			off := node.kind >> 32
			src := unsafe.Slice((*int32)(unsafe.Add(unsafe.Pointer(unsafe.SliceData(t.data)), off)), node.misc)
			g.buf = append(g.buf, '[')
			for i, v := range src {
				if i > 0 {
					g.buf = append(g.buf, ',')
				}
				g.buf = strconv.AppendInt(g.buf, int64(v), 10)
			}
			g.buf = append(g.buf, ']')
		case prettyViewKindValueInt64Slice:
			off := node.kind >> 32
			src := unsafe.Slice((*int64)(unsafe.Add(unsafe.Pointer(unsafe.SliceData(t.data)), off)), node.misc)
			g.buf = append(g.buf, '[')
			for i, v := range src {
				if i > 0 {
					g.buf = append(g.buf, ',')
				}
				g.buf = strconv.AppendInt(g.buf, int64(v), 10)
			}
			g.buf = append(g.buf, ']')
		case prettyViewKindValueUintSlice:
			off := node.kind >> 32
			src := unsafe.Slice((*uint)(unsafe.Add(unsafe.Pointer(unsafe.SliceData(t.data)), off)), node.misc)
			g.buf = append(g.buf, '[')
			for i, v := range src {
				if i > 0 {
					g.buf = append(g.buf, ',')
				}
				g.buf = strconv.AppendUint(g.buf, uint64(v), 10)
			}
			g.buf = append(g.buf, ']')
		case prettyViewKindValueUint8Slice:
			off := node.kind >> 32
			src := unsafe.Slice((*uint8)(unsafe.Add(unsafe.Pointer(unsafe.SliceData(t.data)), off)), node.misc)
			g.buf = append(g.buf, '[')
			for i, v := range src {
				if i > 0 {
					g.buf = append(g.buf, ',')
				}
				g.buf = strconv.AppendUint(g.buf, uint64(v), 10)
			}
			g.buf = append(g.buf, ']')
		case prettyViewKindValueUint16Slice:
			off := node.kind >> 32
			src := unsafe.Slice((*uint16)(unsafe.Add(unsafe.Pointer(unsafe.SliceData(t.data)), off)), node.misc)
			g.buf = append(g.buf, '[')
			for i, v := range src {
				if i > 0 {
					g.buf = append(g.buf, ',')
				}
				g.buf = strconv.AppendUint(g.buf, uint64(v), 10)
			}
			g.buf = append(g.buf, ']')
		case prettyViewKindValueUint32Slice:
			off := node.kind >> 32
			src := unsafe.Slice((*uint32)(unsafe.Add(unsafe.Pointer(unsafe.SliceData(t.data)), off)), node.misc)
			g.buf = append(g.buf, '[')
			for i, v := range src {
				if i > 0 {
					g.buf = append(g.buf, ',')
				}
				g.buf = strconv.AppendUint(g.buf, uint64(v), 10)
			}
			g.buf = append(g.buf, ']')
		case prettyViewKindValueUint64Slice:
			off := node.kind >> 32
			src := unsafe.Slice((*uint64)(unsafe.Add(unsafe.Pointer(unsafe.SliceData(t.data)), off)), node.misc)
			g.buf = append(g.buf, '[')
			for i, v := range src {
				if i > 0 {
					g.buf = append(g.buf, ',')
				}
				g.buf = strconv.AppendUint(g.buf, uint64(v), 10)
			}
			g.buf = append(g.buf, ']')
		case prettyViewKindValueFloat32Slice:
			off := node.kind >> 32
			src := unsafe.Slice((*float32)(unsafe.Add(unsafe.Pointer(unsafe.SliceData(t.data)), off)), node.misc)
			g.buf = append(g.buf, '[')
			for i, v := range src {
				if i > 0 {
					g.buf = append(g.buf, ',')
				}
				g.buf = strconv.AppendFloat(g.buf, float64(v), 'g', -1, 32)
			}
			g.buf = append(g.buf, ']')
		case prettyViewKindValueFloat64Slice:
			off := node.kind >> 32
			src := unsafe.Slice((*float64)(unsafe.Add(unsafe.Pointer(unsafe.SliceData(t.data)), off)), node.misc)
			g.buf = append(g.buf, '[')
			for i, v := range src {
				if i > 0 {
					g.buf = append(g.buf, ',')
				}
				g.buf = strconv.AppendFloat(g.buf, float64(v), 'g', -1, 64)
			}
			g.buf = append(g.buf, ']')
		case prettyViewKindValueStringSlice:
			g.buf = append(g.buf, '[')
			src := unsafe.Add(unsafe.Pointer(unsafe.SliceData(t.data)), node.kind>>32)
			length := int(node.misc)
			for i := range length {
				lens := *(*uint32)(src)
				if i > 0 {
					g.buf = append(g.buf, ',')
				}
				str := unsafe.String((*byte)(unsafe.Add(src, 4)), lens)
				g.buf = strconv.AppendQuote(g.buf, str)
				src = unsafe.Add(src, 4+lens)
			}
			g.buf = append(g.buf, ']')
		default:
			g.buf = strconv.AppendQuote(g.buf, (node.kind & 0x1F).String())
		}

		if node.next == 0 {
			for len(stack) > 0 {
				g.buf = append(g.buf, '}')
				pos, stack = stack[len(stack)-1], stack[:len(stack)-1]
				node = (*prettyViewNode)(unsafe.Add(unsafe.Pointer(unsafe.SliceData(ctrl)), pos))
				if node.next != 0 {
					pos = int(node.next)
					old = true
					continue mainLoop
				}
			}
			break
		}
		pos = int(node.next)
	}
	g.buf = append(g.buf, '}')
}

func (g *JSONWriter) browseCtrl() {
	clen := g.view.tree.clen
	var pos int
	for pos < clen {
		node := (*prettyViewNode)(unsafe.Add(unsafe.Pointer(unsafe.SliceData(g.view.tree.ctrl)), pos))
		fmt.Printf("%03x %q -> kind[%s] next[%03x] misc[%03x]\n", pos, g.view.tree.unpackKey(node), node.kind&0x1F, node.next, node.misc)
		pos += prettyViewNodeSize
	}
}

func (g *JSONWriter) unpackBoolsJSON(node *prettyViewNode) {
	g.buf = append(g.buf, '[')
	bytesNo := (node.misc + 7) / 8
	rest := node.misc
	src := unsafe.Slice((*byte)(unsafe.Add(unsafe.Pointer(unsafe.SliceData(g.view.tree.data)), node.kind>>32)), bytesNo)
	for _, b := range src {
		l := min(8, rest)
		for range l {
			if b&0x01 > 0 {
				g.buf = append(g.buf, "true,"...)
			} else {
				g.buf = append(g.buf, "false,"...)
			}
			b >>= 1
		}
	}
	g.buf = g.buf[:len(g.buf)-1]
	g.buf = append(g.buf, ']')
}