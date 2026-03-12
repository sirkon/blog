package blog

import (
	"encoding/base64"
	"math"
	"strconv"
	"time"
	"unsafe"
)

// walkJSON adds new line. All walkers must put new line themselves.
func (g *PrettyWriter) walkJSON() {
	g.buf = append(g.buf, '{')
	var pos int
	stack := g.stack
	ctrl := g.view.tree.ctrl
	t := g.view.tree
	var old bool

	if t.clen == 0 {
		g.buf = append(g.buf, '}', '\n')
		return
	}

mainLoop:
	for {
		node := (*prettyViewNode)(unsafe.Add(unsafe.Pointer(unsafe.SliceData(ctrl)), pos))

		// Draw a key
		key := t.unpackKey(node)
		if old {
			g.buf = append(g.buf, ',', ' ')
		}
		old = true
		g.colorKey()
		g.buf = strconv.AppendQuote(g.buf, key)
		g.colorReset()
		g.buf = append(g.buf, ':', ' ')

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
						g.buf = append(g.buf, "true, "...)
					} else {
						g.buf = append(g.buf, "false, "...)
					}
					part1 >>= 1
				}
			} else {
				for range 52 {
					if part1&0x01 != 0 {
						g.buf = append(g.buf, "true, "...)
					} else {
						g.buf = append(g.buf, "false, "...)
					}
					part1 >>= 1
				}
				length -= 52
				for range length {
					if part2&0x01 != 0 {
						g.buf = append(g.buf, "true, "...)
					} else {
						g.buf = append(g.buf, "false, "...)
					}
					part2 >>= 1
				}
			}
			g.buf = g.buf[:len(g.buf)-2]
			g.buf = append(g.buf, ']')
		case prettyViewKindValueIntSlice:
			off := node.kind >> 32
			src := unsafe.Slice((*int)(unsafe.Add(unsafe.Pointer(unsafe.SliceData(t.data)), off)), node.misc)
			g.buf = append(g.buf, '[')
			for i, v := range src {
				if i > 0 {
					g.buf = append(g.buf, ',', ' ')
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
					g.buf = append(g.buf, ',', ' ')
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
					g.buf = append(g.buf, ',', ' ')
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
					g.buf = append(g.buf, ',', ' ')
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
					g.buf = append(g.buf, ',', ' ')
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
					g.buf = append(g.buf, ',', ' ')
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
					g.buf = append(g.buf, ',', ' ')
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
					g.buf = append(g.buf, ',', ' ')
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
					g.buf = append(g.buf, ',', ' ')
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
					g.buf = append(g.buf, ',', ' ')
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
					g.buf = append(g.buf, ',', ' ')
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
					g.buf = append(g.buf, ',', ' ')
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
					g.buf = append(g.buf, ',', ' ')
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
	g.stack = stack
	g.buf = append(g.buf, '}', '\n')
}
