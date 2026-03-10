//go:build arm64 || amd64 || riscv64

package blog

import (
	"encoding/binary"
	"unsafe"
)

// AddBoolArray adds an array of bools packed as bitmaps.
// Need to use binary.BigEndian on big endian architectures, probably.
func (t *packedTree) AddBoolArray(prev int, key []byte, data []bool) int {
	off := len(t.ctrl)
	t.ensureSpace()
	base := unsafe.Pointer(unsafe.SliceData(t.ctrl))
	t.linkToPrev(prev, off)
	respt := (*prettyViewObjNode)(unsafe.Add(base, off))

	if len(data) > 84 {
		// Do this straightforwardly.
		var dst uint64
		var i int
		dataOff := len(t.data)
		for _, b := range data {
			if b {
				dst |= 1 << i
			}
			i++
			if i == 64 {
				t.data = binary.LittleEndian.AppendUint64(t.data, dst)
				dst = 0
				i = 0
			}
		}
		if i > 0 {
			// We'll keep more bytes, this 7 just bytes overhead at max. And since this is a log we won't
			// have much of them. Well, I doubt if we'll have them at all, never seen anyone who tried
			// to output an array of booleans LMAO.
			t.data = binary.LittleEndian.AppendUint64(t.data, dst)
		}
		*respt = prettyViewObjNode{
			key:  t.packKey(key),
			kind: prettyViewKindValueBoolSlice | prettyViewKind(dataOff<<32),
			misc: uint32(len(data)),
		}
		t.ctrl = unsafe.Slice((*byte)(base), off+prettyViewObjNodeSize)
		return off
	}

	var part1 uint64
	var part2 uint64
	l := min(len(data), 64)
	for i, b := range data[:l] {
		if b {
			part1 |= 1 << i
		}
	}
	if len(data) > 64 {
		for i, b := range data[l:] {
			if b {
				part2 |= 1 << i
			}
		}
	}
	kindMask := (uint64(len(data)) << 57 >> 52) | part1<<12
	misc := part1>>52 | part2<<12
	*respt = prettyViewObjNode{
		key:  t.packKey(key),
		kind: prettyViewKindValueBoolSliceShort | prettyViewKind(kindMask),
		misc: uint32(misc),
	}
	t.ctrl = unsafe.Slice((*byte)(base), off+prettyViewObjNodeSize)
	return off
}

// Big endian one will not need right bit shift by 32 for the offset.
func (t *packedTree) packKey(key []byte) uint64 {
	if len(key) > 8 {
		off := len(t.data)
		t.data = append(t.data, key...)
		return uint64(off)<<32 | uint64(len(key))<<8
	}
	var res uint64
	dst := unsafe.Slice((*byte)(unsafe.Pointer(&res)), 8)
	copy(dst, key)
	return res
}

// Big endian one may require different directions and values of bit shifts.
// Also binary.BigEndian instead of binary.LittleEndian.
func (t *packedTree) packStringValue(n *prettyViewObjNode, s []byte) int {
	switch len(s) {
	case 0:
		// bits are zero, everything is zero. This means the string is empty. Do nothing here.
		n.kind = prettyViewKindValueStringShort
	case 1, 2, 3, 4, 5, 6, 7:
		var data uint64
		dst := unsafe.Slice((*byte)(unsafe.Pointer(&data)), 8)
		copy(dst, s)
		n.kind = prettyViewKind(uint64(prettyViewKindValueStringShort) | uint64(len(s)<<5) | data<<8)
	case 8, 9, 10:
		// Write 6 bytes into the 3…8 bytes of kind.
		var buf [16]byte
		copy(buf[:], s)
		src := unsafe.Pointer(&buf[0])
		v1 := *(*uint64)(unsafe.Pointer(src))
		v2 := *(*uint64)(unsafe.Add(unsafe.Pointer(src), 8))

		n.kind = prettyViewKindValueStringShort | prettyViewKind(uint64(len(s))<<8) | prettyViewKind(v1<<16)
		n.misc = uint32((v1 >> 48) | v2<<16)
	default:
		off := len(t.data)
		t.data = append(t.data, s...)
		n.kind = prettyViewKind(uint64(prettyViewKindValueString) | uint64(off<<32))
		n.misc = uint32(len(s))
	}
	return 0
}

// Big endian one may require different directions and values of bit shifts.
// Also, binary.BigEndian instead of binary.LittleEndian.
func (t *packedTree) packBytesValue(n *prettyViewObjNode, s []byte) int {
	switch len(s) {
	case 0:
		// bits are zero, everything is zero. This means the string is empty. Do nothing here.
		n.kind = prettyViewKindValueByteSliceShort
	case 1, 2, 3, 4, 5, 6, 7:
		var data uint64
		dst := unsafe.Slice((*byte)(unsafe.Pointer(&data)), 8)
		copy(dst, s)
		n.kind = prettyViewKind(uint64(prettyViewKindValueByteSliceShort) | uint64(len(s)<<5) | data<<8)
	case 8, 9, 10:
		// Write 6 bytes into the 3…8 bytes of kind.
		var buf [16]byte
		copy(buf[:], s)
		src := unsafe.Pointer(&buf[0])
		v1 := *(*uint64)(unsafe.Pointer(src))
		v2 := *(*uint64)(unsafe.Add(unsafe.Pointer(src), 8))

		n.kind = prettyViewKindValueByteSliceShort | prettyViewKind(uint64(len(s))<<8) | prettyViewKind(v1<<16)
		n.misc = uint32((v1 >> 48) | v2<<16)
	default:
		off := len(t.data)
		t.data = append(t.data, s...)
		n.kind = prettyViewKind(uint64(prettyViewKindValueByteSlice) | uint64(off<<32))
		n.misc = uint32(len(s))
	}
	return 0
}

func (t *packedTree) packStringSlice(data [][]byte) {
	for _, d := range data {
		if len(d) > maxStringLen {
			d = d[:maxStringLen]
		}
		t.data = binary.LittleEndian.AppendUint32(t.data, uint32(len(d)))
		t.data = append(t.data, d...)
	}
}
