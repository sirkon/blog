package blog

import (
	"encoding/base64"
	"math"
	"strconv"
	"time"
	"unsafe"
)

func (g *PrettyWriter) walkTree() {
	var pos int

	stack := g.stack
	branch := g.branch

	ctrl := g.view.tree.ctrl
	t := g.view.tree
	errps := g.view.ctx.errors

mainLoop:
	for {
		node := (*prettyViewNode)(unsafe.Add(
			unsafe.Pointer(unsafe.SliceData(ctrl)),
			pos,
		))

		key := t.unpackKey(node)

		last := node.next == 0

		// draw tree prefix
		g.drawPrefix(branch, last, false)

		var errFound bool
		for _, pp := range errps {
			if pp == pos {
				errFound = true
			}
		}
		errFound = errFound

		if !errFound {
			g.colorKey()
		} else {
			g.colorErrKey()
		}
		g.buf = append(g.buf, key...)
		g.colorReset()

		switch node.kind & 0x1F {

		case prettyViewKindRoot:
			if node.misc == math.MaxUint32 {
				g.buf = append(g.buf, ':', ' ', '{', '}')
				break
			}

			g.buf = append(g.buf, '\n')
			stack = append(stack, pos)
			branch = append(branch, !last)

			pos = int(node.misc)
			continue

		case prettyViewKindValueBool:

			g.buf = append(g.buf, ':', ' ')
			if node.kind>>8 != 0 {
				g.buf = append(g.buf, "true"...)
			} else {
				g.buf = append(g.buf, "false"...)
			}

		case prettyViewKindValueTime:

			g.buf = append(g.buf, ':', ' ')
			g.buf = append(
				g.buf,
				time.Unix(
					0,
					int64(unpackFullNum(node.kind, node.misc)),
				).Format(time.RFC3339Nano)...,
			)

		case prettyViewKindValueDuration:

			g.buf = append(g.buf, ':', ' ')
			g.buf = append(
				g.buf,
				time.Duration(
					unpackFullNum(node.kind, node.misc),
				).String()...,
			)

		case prettyViewKindValueInt:

			g.buf = append(g.buf, ':', ' ')
			g.buf = strconv.AppendInt(
				g.buf,
				int64(unpackFullNum(node.kind, node.misc)),
				10,
			)

		case prettyViewKindValueUint:

			g.buf = append(g.buf, ':', ' ')
			g.buf = strconv.AppendUint(
				g.buf,
				unpackFullNum(node.kind, node.misc),
				10,
			)

		case prettyViewKindValueFloat:

			g.buf = append(g.buf, ':', ' ')

			value := math.Float64frombits(
				unpackFullNum(node.kind, node.misc),
			)

			g.buf = strconv.AppendFloat(
				g.buf,
				value,
				'g',
				-1,
				64,
			)

		case prettyViewKindValueString:

			if errFound {
				g.colorErrKey()
			}
			g.buf = append(g.buf, ':', ' ')

			off := node.kind >> 32

			value := unsafe.String(
				(*byte)(unsafe.Add(
					unsafe.Pointer(unsafe.SliceData(t.data)),
					off,
				)),
				node.misc,
			)

			if !errFound {
				if key == "@location" {
					g.colorLocation()
				}
				g.buf = append(g.buf, value...)
				break
			}
			g.colorLevelError()
			g.buf = append(g.buf, value...)
			g.colorReset()

		case prettyViewKindValueStringShort:
			if errFound {
				g.colorErrKey()
			}
			g.buf = append(g.buf, ':', ' ')

			var shortPlace uint64
			var longPlace [16]byte

			value := unpackShortStringValue(
				node,
				&shortPlace,
				longPlace,
			)

			if !errFound {
				g.buf = append(g.buf, value...)
				break
			}
			g.colorLevelError()
			g.buf = append(g.buf, value...)
			g.colorReset()

		case prettyViewKindValueByteSlice:

			g.buf = append(g.buf, ':', ' ')

			off := node.kind >> 32

			value := unsafe.Slice(
				(*byte)(unsafe.Add(
					unsafe.Pointer(unsafe.SliceData(t.data)),
					off,
				)),
				node.misc,
			)

			g.buf = append(g.buf, "base64."...)
			g.buf = base64.RawStdEncoding.AppendEncode(g.buf, value)

		case prettyViewKindValueByteSliceShort:

			g.buf = append(g.buf, ':', ' ')
			var shortPlace uint64
			var longPlace [16]byte

			value := unpackShortStringValue(
				node,
				&shortPlace,
				longPlace,
			)

			g.buf = append(g.buf, "base64."...)
			g.buf = base64.RawStdEncoding.AppendEncode(g.buf, value)

		case prettyViewKindValueBoolSlice:
			g.unpackBoolsTree(node)

		case prettyViewKindValueBoolSliceShort:
			g.formatShortBool(node)

		case prettyViewKindValueIntSlice, prettyViewKindValueInt64Slice:
			formatIntSlice[int64](g, node, t)

		case prettyViewKindValueInt8Slice:
			formatIntSlice[int8](g, node, t)

		case prettyViewKindValueInt16Slice:
			formatIntSlice[int16](g, node, t)

		case prettyViewKindValueInt32Slice:
			formatIntSlice[int32](g, node, t)

		case prettyViewKindValueUintSlice, prettyViewKindValueUint64Slice:
			formatUintSlice[uint64](g, node, t)

		case prettyViewKindValueUint8Slice:
			formatUintSlice[uint8](g, node, t)

		case prettyViewKindValueUint16Slice:
			formatUintSlice[uint16](g, node, t)

		case prettyViewKindValueUint32Slice:
			formatUintSlice[uint32](g, node, t)

		case prettyViewKindValueFloat32Slice:
			formatFloatSlice[float32](g, node, t, 32)

		case prettyViewKindValueFloat64Slice:
			formatFloatSlice[float64](g, node, t, 64)

		case prettyViewKindValueStringSlice:
			g.formatStringSlice(node, t)

		default:

			g.buf = append(g.buf, ':', ' ')
			g.buf = strconv.AppendQuote(
				g.buf,
				(node.kind & 0x1F).String(),
			)
		}

		g.buf = append(g.buf, '\n')

		if node.next == 0 {

			for len(stack) > 0 {

				pos = stack[len(stack)-1]
				stack = stack[:len(stack)-1]

				branch = branch[:len(branch)-1]

				node = (*prettyViewNode)(unsafe.Add(
					unsafe.Pointer(unsafe.SliceData(ctrl)),
					pos,
				))

				if node.next != 0 {

					pos = int(node.next)
					continue mainLoop
				}
			}

			break
		}

		pos = int(node.next)
	}

	g.stack = stack
	g.branch = branch
}

func formatIntSlice[T int8 | int16 | int32 | int64](g *PrettyWriter, node *prettyViewNode, t *packedTree) {
	off := node.kind >> 32
	src := unsafe.Slice((*T)(unsafe.Add(unsafe.Pointer(unsafe.SliceData(t.data)), off)), node.misc)
	length := int(node.misc)
	switch length {
	case 0:
		g.buf = append(g.buf, ':', ' ', '[', ']')
	case 1, 2, 3, 4, 5, 6, 7, 8:
		g.buf = append(g.buf, ':', ' ')
		for i, v := range src {
			if i > 0 {
				g.buf = append(g.buf, ',', ' ')
			}
			g.buf = strconv.AppendInt(g.buf, int64(v), 10)
		}
	default:
		g.buf = append(g.buf, '\n')
		g.branch = append(g.branch, true)
		for i, v := range src {
			g.drawPrefix(g.branch, i == len(src)-1, node.misc == 0)
			g.buf = strconv.AppendInt(g.buf, int64(i), 10)
			g.buf = append(g.buf, ':', ' ')
			g.buf = strconv.AppendInt(g.buf, int64(v), 10)
			g.buf = append(g.buf, '\n')
		}
		g.branch = g.branch[:len(g.branch)-1]
		g.buf = g.buf[:len(g.buf)-1]
	}
}

func formatUintSlice[T uint8 | uint16 | uint32 | uint64](g *PrettyWriter, node *prettyViewNode, t *packedTree) {
	off := node.kind >> 32
	src := unsafe.Slice((*T)(unsafe.Add(unsafe.Pointer(unsafe.SliceData(t.data)), off)), node.misc)
	length := int(node.misc)
	switch length {
	case 0:
		g.buf = append(g.buf, ':', ' ', '[', ']')
	case 1, 2, 3, 4, 5, 6, 7, 8:
		g.buf = append(g.buf, ':', ' ')
		for i, v := range src {
			if i > 0 {
				g.buf = append(g.buf, ',', ' ')
			}
			g.buf = strconv.AppendUint(g.buf, uint64(v), 10)
		}
	default:
		g.buf = append(g.buf, '\n')
		g.branch = append(g.branch, true)
		for i, v := range src {
			g.drawPrefix(g.branch, i == len(src)-1, node.misc == 0)
			g.buf = strconv.AppendUint(g.buf, uint64(i), 10)
			g.buf = append(g.buf, ':', ' ')
			g.buf = strconv.AppendUint(g.buf, uint64(v), 10)
			g.buf = append(g.buf, '\n')
		}
		g.branch = g.branch[:len(g.branch)-1]
		g.buf = g.buf[:len(g.buf)-1]
	}
}

func formatFloatSlice[T float32 | float64](g *PrettyWriter, node *prettyViewNode, t *packedTree, bits int) {
	off := node.kind >> 32
	src := unsafe.Slice((*T)(unsafe.Add(unsafe.Pointer(unsafe.SliceData(t.data)), off)), node.misc)
	length := int(node.misc)
	switch length {
	case 0:
		g.buf = append(g.buf, ':', ' ', '[', ']')
	case 1, 2, 3, 4, 5, 6, 7, 8:
		g.buf = append(g.buf, ':', ' ')
		for i, v := range src {
			if i > 0 {
				g.buf = append(g.buf, ',', ' ')
			}
			g.buf = strconv.AppendFloat(g.buf, float64(v), 'g', -1, bits)
		}
	default:
		g.buf = append(g.buf, '\n')
		g.branch = append(g.branch, true)
		for i, v := range src {
			g.drawPrefix(g.branch, i == len(src)-1, node.misc == 0)
			g.buf = strconv.AppendUint(g.buf, uint64(i), 10)
			g.buf = append(g.buf, ':', ' ')
			g.buf = strconv.AppendFloat(g.buf, float64(v), 'g', -1, bits)
			g.buf = append(g.buf, '\n')
		}
		g.branch = g.branch[:len(g.branch)-1]
		g.buf = g.buf[:len(g.buf)-1]
	}
}

func (g *PrettyWriter) formatStringSlice(node *prettyViewNode, t *packedTree) {
	src := unsafe.Add(unsafe.Pointer(unsafe.SliceData(t.data)), node.kind>>32)
	length := int(node.misc)
	switch length {
	case 0:
		g.buf = append(g.buf, ':', ' ', '[', ']')
	case 1, 2, 3, 4, 5, 6, 7, 8:
		g.buf = append(g.buf, ':', ' ')
		for i := range length {
			lens := *(*uint32)(src)
			if i > 0 {
				g.buf = append(g.buf, ',', ' ')
			}
			str := unsafe.String((*byte)(unsafe.Add(src, 4)), lens)
			g.buf = strconv.AppendQuote(g.buf, str)
			src = unsafe.Add(src, 4+lens)
		}
	default:
		g.buf = append(g.buf, '\n')
		g.branch = append(g.branch, true)
		for i := range length {
			g.drawPrefix(g.branch, i == length-1, node.misc == 0)
			g.buf = strconv.AppendUint(g.buf, uint64(i), 10)
			g.buf = append(g.buf, ':', ' ')
			lens := *(*uint32)(src)
			str := unsafe.String((*byte)(unsafe.Add(src, 4)), lens)
			g.buf = append(g.buf, str...)
			g.buf = append(g.buf, '\n')
			src = unsafe.Add(src, 4+lens)
		}
		g.branch = g.branch[:len(g.branch)-1]
		g.buf = g.buf[:len(g.buf)-1]
	}
}

func (g *PrettyWriter) formatShortBool(node *prettyViewNode) {
	length := node.kind << 52 >> 57
	if length == 0 {
		g.buf = append(g.buf, ": []"...)
		return
	}
	part1 := node.kind >> 12
	part2 := node.misc
	switch {
	case length <= 8:
		g.buf = append(g.buf, ':', ' ')
		for range length {
			if part1&0x01 != 0 {
				g.buf = append(g.buf, "true, "...)
			} else {
				g.buf = append(g.buf, "false, "...)
			}
			part1 >>= 1
		}
		g.buf = g.buf[:len(g.buf)-2]
	case length <= 52:
		g.branch = append(g.branch, true)
		g.buf = append(g.buf, '\n')
		for i := range length {
			g.drawPrefix(g.branch, i == length-1, node.misc == 0)
			g.buf = strconv.AppendInt(g.buf, int64(i), 10)
			g.buf = append(g.buf, ':', ' ')
			if part1&0x01 != 0 {
				g.buf = append(g.buf, "true"...)
			} else {
				g.buf = append(g.buf, "false"...)
			}
			g.buf = append(g.buf, '\n')
			part1 >>= 1
		}
		g.branch = g.branch[:len(g.branch)-1]
		g.buf = g.buf[:len(g.buf)-1]
	default:
		g.branch = append(g.branch, true)
		g.buf = append(g.buf, '\n')
		for i := range 52 {
			g.drawPrefix(g.branch, false, node.misc == 0)
			g.buf = strconv.AppendInt(g.buf, int64(i), 10)
			g.buf = append(g.buf, ':', ' ')
			if part1&0x01 != 0 {
				g.buf = append(g.buf, "true"...)
			} else {
				g.buf = append(g.buf, "false"...)
			}
			g.buf = append(g.buf, '\n')
			part1 >>= 1
		}
		length -= 52
		for i := range length {
			g.drawPrefix(g.branch, i == length-1, node.misc == 0)
			g.buf = strconv.AppendInt(g.buf, int64(i+52), 10)
			g.buf = append(g.buf, ':', ' ')
			if part2&0x01 != 0 {
				g.buf = append(g.buf, "true"...)
			} else {
				g.buf = append(g.buf, "false"...)
			}
			g.buf = append(g.buf, '\n')
			part2 >>= 1
		}
		g.branch = g.branch[:len(g.branch)-1]
		g.buf = g.buf[:len(g.buf)-1]
	}
}

func (g *PrettyWriter) drawPrefix(branch []bool, last bool, inLast bool) {
	g.colorLink()
	for i := 0; i < len(branch); i++ {
		if branch[i] {
			if !inLast {
				g.buf = append(g.buf, "│  "...)
			} else {
				g.buf = append(g.buf, "   "...)
			}
		} else {
			g.buf = append(g.buf, "   "...)
		}
	}

	if last {
		g.buf = append(g.buf, "└─ "...)
	} else {
		g.buf = append(g.buf, "├─ "...)
	}
	g.colorReset()
}
