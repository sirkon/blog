package blog

import (
	"encoding/base64"
	"fmt"
	"go/token"
	"io"
	"math"
	"os"
	"strconv"
	"time"
	"unsafe"

	"github.com/sirkon/blog/internal/core"
)

type PrettyWriter struct {
	w     io.Writer
	view  *packedDeconstruct
	buf   []byte
	stack []int
}

func NewPrettyWriter(w io.Writer) *PrettyWriter {
	tree := &packedTree{}
	ctx := &packedContextDeconstruct{
		tree: tree,
	}
	return &PrettyWriter{
		w: w,
		view: &packedDeconstruct{
			tree: tree,
			ctx:  ctx,
		},
	}
}

func (g *PrettyWriter) Write(p []byte) (n int, err error) {
	g.view.loc = token.Position{}
	g.view.tree.Reset()
	g.view.ctx.Reset()
	g.buf = g.buf[:0]
	g.stack = g.stack[:0]

	if err := core.ProcessRecord(p, g.view); err != nil {
		return 0, core.WrapError(err, "process record")
	}

	// TODO добавить ANSI-кодов для цвета и прочего
	g.formatTime()
	g.buf = append(g.buf, ' ')
	g.formatLevel()
	g.buf = append(g.buf, ' ')
	if g.view.loc.IsValid() {
		g.formatLocation()
		g.buf = append(g.buf, ' ')
	}

	// TODO описать логику отрисовки при PANIC: в message там лежит стектрейс.
	//      Нужно отрисовать контекст в JSON, а снизу с отступом стектрейс.

	// TODO добавить ANSI.
	g.buf = append(g.buf, g.view.msg...)
	g.buf = append(g.buf, ' ', ' ')

	// TODO добавить ANSI для контекста
	// TODO не JSON если len(g.view.ctx.errors) > 0.
	g.walkJSON()

	if _, err := g.w.Write(g.buf); err != nil {
		_, _ = fmt.Fprintln(os.Stderr, "failed to write buffer:", err)
	}

	return len(p), nil
}

// walkJSON adds new line. All walkers must put new line themselves.
func (g *PrettyWriter) walkJSON() {
	g.buf = append(g.buf, '{')
	var pos int
	stack := g.stack
	ctrl := g.view.tree.ctrl
	t := g.view.tree
	var old bool
	for {
		node := (*prettyViewObjNode)(unsafe.Add(unsafe.Pointer(unsafe.SliceData(ctrl)), pos))

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
			g.buf = append(g.buf, "NULL"...)
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
			g.unpackBools(node)
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
			src := unsafe.Slice((*uint)(unsafe.Add(unsafe.Pointer(unsafe.SliceData(t.data)), off)), node.misc)
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
			break
		}
		pos = int(node.next)
	}
	g.stack = stack
	g.buf = append(g.buf, '}', '\n')
}

func (g *PrettyWriter) formatTime() {
	t := g.view.time
	g.buf = strconv.AppendInt(g.buf, int64(t.Year()), 10)
	g.buf = append(g.buf, '-')
	if t.Month() < 10 {
		g.buf = append(g.buf, '0')
	}
	g.buf = strconv.AppendInt(g.buf, int64(t.Month()), 10)
	g.buf = append(g.buf, '-')
	if t.Day() < 10 {
		g.buf = append(g.buf, '0')
	}
	g.buf = strconv.AppendInt(g.buf, int64(t.Day()), 10)
	g.buf = append(g.buf, ' ')
	if t.Hour() < 10 {
		g.buf = append(g.buf, '0')
	}
	g.buf = strconv.AppendInt(g.buf, int64(t.Hour()), 10)
	g.buf = append(g.buf, ':')
	if t.Minute() < 10 {
		g.buf = append(g.buf, '0')
	}
	g.buf = strconv.AppendInt(g.buf, int64(t.Minute()), 10)
	g.buf = append(g.buf, ':')
	if t.Second() < 10 {
		g.buf = append(g.buf, '0')
	}
	g.buf = strconv.AppendInt(g.buf, int64(t.Second()), 10)
	g.buf = append(g.buf, '.')
	ms := (t.Nanosecond() / 1_000_000) % 1_000
	if ms < 100 {
		if ms < 10 {
			g.buf = append(g.buf, '0')
		}
		g.buf = append(g.buf, ' ')
	}
	g.buf = strconv.AppendInt(g.buf, int64(ms), 10)
}

func (g *PrettyWriter) formatLevel() {
	// TODO добавить ANSI
	switch g.view.level {
	case LevelTrace:
		g.buf = append(g.buf, "TRACE"...)
	case LevelDebug:
		g.buf = append(g.buf, "DEBUG"...)
	case LevelInfo:
		g.buf = append(g.buf, "INFO "...)
	case LevelWarning:
		g.buf = append(g.buf, "WARN "...)
	case LevelError:
		g.buf = append(g.buf, "ERROR"...)
	case core.LoggingLevelPanic:
		g.buf = append(g.buf, "PANIC"...)
	default:
		g.buf = append(g.buf, "UNKWN"...)
	}
}

func (g *PrettyWriter) formatLocation() {
	// TODO добавить ANSI
	loc := g.view.loc
	g.buf = append(g.buf, loc.Filename...)
	g.buf = append(g.buf, ':')
	g.buf = strconv.AppendInt(g.buf, int64(loc.Line), 10)
}
