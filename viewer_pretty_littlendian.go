//go:build arm64 || amd64 || riscv64

package blog

import (
	"math/bits"
	"strconv"
	"unsafe"
)

func (t *packedTree) unpackKey(node *prettyViewNode) string {
	if node.key<<56 != 0 {
		// Short key.
		length := 8 - bits.LeadingZeros64(node.key)/8
		return unsafe.String((*byte)(unsafe.Pointer(&node.key)), length)
	}

	// long key
	off := node.key >> 32
	length := node.key << 32 >> 40
	ptr := (*byte)(unsafe.Add(unsafe.Pointer(unsafe.SliceData(t.data)), off))
	return unsafe.String(ptr, length)
}

func unpackShortStringValue(n *prettyViewNode, shortPlaceholder *uint64, longPlaceholder [16]byte) []byte {
	if n.kind>>8 == 0 {
		return nil
	}

	length := n.kind << 56 >> 61
	if length != 0 {
		// The string is up to 7 bytes log placed in the kind.
		*shortPlaceholder = uint64(n.kind >> 8)
		return unsafe.Slice((*byte)(unsafe.Pointer(shortPlaceholder)), length)
	}

	// 8, 9, 10 bytes long string.
	length = n.kind << 48 >> 56
	if length > 10 {
		return []byte("!INVALID-DATA")
	}

	header := uint64(n.kind>>16) | (uint64(n.misc) << 48)
	base := unsafe.Pointer(&longPlaceholder[0])
	*(*uint64)(base) = header
	*(*uint64)(unsafe.Add(base, 8)) = uint64(n.misc) >> 16
	return longPlaceholder[:length]
}

func (g *PrettyWriter) unpackBoolsJSON(node *prettyViewNode) {
	g.buf = append(g.buf, '[')
	bytesNo := (node.misc + 7) / 8
	rest := node.misc
	src := unsafe.Slice((*byte)(unsafe.Add(unsafe.Pointer(unsafe.SliceData(g.view.tree.data)), node.kind>>32)), bytesNo)
	for _, b := range src {
		l := min(8, rest)
		for range l {
			if b&0x01 > 0 {
				g.buf = append(g.buf, "true, "...)
			} else {
				g.buf = append(g.buf, "false, "...)
			}
			b >>= 1
		}
	}
	g.buf = g.buf[:len(g.buf)-2]
	g.buf = append(g.buf, ']')
}

func (g *PrettyWriter) unpackBoolsTree(node *prettyViewNode) {
	bytesNo := (node.misc + 7) / 8
	rest := node.misc
	src := unsafe.Slice((*byte)(unsafe.Add(unsafe.Pointer(unsafe.SliceData(g.view.tree.data)), node.kind>>32)), bytesNo)

	g.buf = append(g.buf, '\n')
	g.branch = append(g.branch, true)
	for i, b := range src {
		l := min(8, rest)
		for j := range l {
			g.drawPrefix(g.branch, i*8+int(j) == int(node.misc)-1, node.next == 0)
			g.buf = strconv.AppendInt(g.buf, int64(i*8+int(j)), 10)
			g.buf = append(g.buf, ':', ' ')
			if b&0x01 > 0 {
				g.buf = append(g.buf, "true"...)
			} else {
				g.buf = append(g.buf, "false"...)
			}
			g.buf = append(g.buf, '\n')
			b >>= 1
		}
	}
	g.buf = g.buf[:len(g.buf)-1]
	g.branch = g.branch[:len(g.branch)-1]
}
