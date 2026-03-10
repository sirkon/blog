package blog

import (
	"math"
	"math/bits"
	"strconv"
	"time"
	"unsafe"
)

const maxStringLen = 1 << 20

type packedTree struct {
	ctrl []byte
	data []byte
}

func (t *packedTree) Reset() {
	t.ctrl = t.ctrl[:0]
	t.data = t.data[:0]
}

func (t *packedTree) ensureSpace() {
	if cap(t.ctrl)-len(t.ctrl) < prettyViewObjNodeSize {
		t.ctrl = append(t.ctrl, prettyViewObjNodePlaceholder[:]...)
	}
}

func (t *packedTree) AddObjectRoot(prev int, key []byte) int {
	off := len(t.ctrl)
	t.ensureSpace()
	base := unsafe.Pointer(unsafe.SliceData(t.ctrl))
	t.linkToPrev(prev, off)
	respt := (*prettyViewObjNode)(unsafe.Add(base, off))
	*respt = prettyViewObjNode{
		key:  t.packKey(key),
		kind: prettyViewKindRoot,
		next: 0,
		misc: 0,
	}
	t.ctrl = unsafe.Slice((*byte)(base), off+prettyViewObjNodeSize)
	return off
}

func (t *packedTree) CloseObjectRoot(prev int) int {
	if prev < 0 {
		return len(t.ctrl)
	}

	base := unsafe.Pointer(unsafe.SliceData(t.ctrl))
	respt := (*prettyViewObjNode)(unsafe.Add(base, prev))
	if respt.kind&0x1F != prettyViewKindRoot {
		// Meaning the root node was added some child nodes, no need to finish it explicitly.
		return len(t.ctrl)
	}

	// We have a group that was not given an element. We put a max of uint32 into misc to tell this.
	// This expresses an impossible state anyway: we can't refer an element whose offset is max uint32
	// because the element itself is 24 bytes long and can't just be fitted in there.
	respt.misc = math.MaxUint32
	return len(t.ctrl)
}

func (t *packedTree) AddString(prev int, key []byte, str []byte) int {
	if len(str) > maxStringLen {
		str = str[:maxStringLen]
	}
	off := len(t.ctrl)
	t.ensureSpace()
	base := unsafe.Pointer(unsafe.SliceData(t.ctrl))
	t.linkToPrev(prev, off)
	respt := (*prettyViewObjNode)(unsafe.Add(base, off))
	*respt = prettyViewObjNode{
		key: t.packKey(key),
	}
	t.packStringValue(respt, str)
	t.ctrl = unsafe.Slice((*byte)(base), off+prettyViewObjNodeSize)
	return off
}

func (t *packedTree) AddBytes(prev int, key []byte, data []byte) int {
	off := len(t.ctrl)
	t.ensureSpace()
	base := unsafe.Pointer(unsafe.SliceData(t.ctrl))
	t.linkToPrev(prev, off)
	respt := (*prettyViewObjNode)(unsafe.Add(base, off))
	*respt = prettyViewObjNode{
		key: t.packKey(key),
	}
	t.packBytesValue(respt, data)
	t.ctrl = unsafe.Slice((*byte)(base), off+prettyViewObjNodeSize)
	return off
}

func (t *packedTree) AddInt(prev int, key []byte, data int64) int {
	off := len(t.ctrl)
	t.ensureSpace()
	base := unsafe.Pointer(unsafe.SliceData(t.ctrl))
	t.linkToPrev(prev, off)
	respt := (*prettyViewObjNode)(unsafe.Add(base, off))
	kindPart, miscPart := packFullNum(uint64(data))
	*respt = prettyViewObjNode{
		key:  t.packKey(key),
		kind: prettyViewKindValueInt | prettyViewKind(kindPart),
		misc: miscPart,
	}
	t.ctrl = unsafe.Slice((*byte)(base), off+prettyViewObjNodeSize)
	return off
}

func (t *packedTree) AddUint(prev int, key []byte, data uint64) int {
	off := len(t.ctrl)
	t.ensureSpace()
	base := unsafe.Pointer(unsafe.SliceData(t.ctrl))
	t.linkToPrev(prev, off)
	respt := (*prettyViewObjNode)(unsafe.Add(base, off))
	kindPart, miscPart := packFullNum(data)
	*respt = prettyViewObjNode{
		key:  t.packKey(key),
		kind: prettyViewKindValueUint | prettyViewKind(kindPart),
		misc: miscPart,
	}
	t.ctrl = unsafe.Slice((*byte)(base), off+prettyViewObjNodeSize)
	return off
}

func (t *packedTree) AddFloat(prev int, key []byte, data float64) int {
	return t.addNumFullWithKind(prev, key, math.Float64bits(data), prettyViewKindValueFloat)
}

func (t *packedTree) AddTime(prev int, key []byte, data time.Time) int {
	return t.addNumFullWithKind(prev, key, uint64(data.UnixNano()), prettyViewKindValueTime)
}

func (t *packedTree) AddDuration(prev int, key []byte, data time.Duration) int {
	return t.addNumFullWithKind(prev, key, uint64(data), prettyViewKindValueDuration)
}

func (t *packedTree) AddBool(prev int, key []byte, data bool) int {
	off := len(t.ctrl)
	t.ensureSpace()
	base := unsafe.Pointer(unsafe.SliceData(t.ctrl))
	t.linkToPrev(prev, off)
	respt := (*prettyViewObjNode)(unsafe.Add(base, off))
	var value uint64
	if data {
		value = 1
	}
	*respt = prettyViewObjNode{
		key:  t.packKey(key),
		kind: prettyViewKindValueBool | prettyViewKind(value<<8),
	}
	t.ctrl = unsafe.Slice((*byte)(base), off+prettyViewObjNodeSize)
	return off
}

func (t *packedTree) AddIntSlice(
	prev int,
	key []byte,
	data []int,
) int {
	rawData := unsafe.Slice(
		(*byte)(unsafe.Pointer(unsafe.SliceData(data))),
		len(data)*8,
	)

	return t.addAnySlice(prev, key, rawData, len(data), prettyViewKindValueIntSlice)
}

func (t *packedTree) AddInt8Slice(
	prev int,
	key []byte,
	data []int8,
) int {
	rawData := unsafe.Slice(
		(*byte)(unsafe.Pointer(unsafe.SliceData(data))),
		len(data),
	)

	return t.addAnySlice(prev, key, rawData, len(data), prettyViewKindValueInt8Slice)
}

func (t *packedTree) AddInt16Slice(
	prev int,
	key []byte,
	data []int16,
) int {
	rawData := unsafe.Slice(
		(*byte)(unsafe.Pointer(unsafe.SliceData(data))),
		len(data)*2,
	)

	return t.addAnySlice(prev, key, rawData, len(data), prettyViewKindValueInt16Slice)
}

func (t *packedTree) AddInt32Slice(
	prev int,
	key []byte,
	data []int32,
) int {
	rawData := unsafe.Slice(
		(*byte)(unsafe.Pointer(unsafe.SliceData(data))),
		len(data)*4,
	)

	return t.addAnySlice(prev, key, rawData, len(data), prettyViewKindValueInt32Slice)
}

func (t *packedTree) AddInt64Slice(
	prev int,
	key []byte,
	data []int64,
) int {
	rawData := unsafe.Slice(
		(*byte)(unsafe.Pointer(unsafe.SliceData(data))),
		len(data)*8,
	)

	return t.addAnySlice(prev, key, rawData, len(data), prettyViewKindValueInt64Slice)
}

func (t *packedTree) AddUintSlice(
	prev int,
	key []byte,
	data []uint,
) int {
	rawData := unsafe.Slice(
		(*byte)(unsafe.Pointer(unsafe.SliceData(data))),
		len(data)*8,
	)

	return t.addAnySlice(prev, key, rawData, len(data), prettyViewKindValueUintSlice)
}

func (t *packedTree) AddUint8Slice(
	prev int,
	key []byte,
	data []uint8,
) int {
	return t.addAnySlice(prev, key, data, len(data), prettyViewKindValueUint8Slice)
}

func (t *packedTree) AddUint16Slice(
	prev int,
	key []byte,
	data []uint16,
) int {
	rawData := unsafe.Slice(
		(*byte)(unsafe.Pointer(unsafe.SliceData(data))),
		len(data)*2,
	)

	return t.addAnySlice(prev, key, rawData, len(data), prettyViewKindValueUint16Slice)
}

func (t *packedTree) AddUint32Slice(
	prev int,
	key []byte,
	data []uint32,
) int {
	rawData := unsafe.Slice(
		(*byte)(unsafe.Pointer(unsafe.SliceData(data))),
		len(data)*4,
	)

	return t.addAnySlice(prev, key, rawData, len(data), prettyViewKindValueUint32Slice)
}

func (t *packedTree) AddUint64Slice(
	prev int,
	key []byte,
	data []uint64,
) int {
	rawData := unsafe.Slice(
		(*byte)(unsafe.Pointer(unsafe.SliceData(data))),
		len(data)*8,
	)

	return t.addAnySlice(prev, key, rawData, len(data), prettyViewKindValueUint64Slice)
}

func (t *packedTree) AddFloat32Slice(
	prev int,
	key []byte,
	data []float32,
) int {
	rawData := unsafe.Slice(
		(*byte)(unsafe.Pointer(unsafe.SliceData(data))),
		len(data)*4,
	)

	return t.addAnySlice(prev, key, rawData, len(data), prettyViewKindValueFloat32Slice)
}

func (t *packedTree) AddFloat64Slice(
	prev int,
	key []byte,
	data []float64,
) int {
	rawData := unsafe.Slice(
		(*byte)(unsafe.Pointer(unsafe.SliceData(data))),
		len(data)*8,
	)

	return t.addAnySlice(prev, key, rawData, len(data), prettyViewKindValueFloat64Slice)
}

func (t *packedTree) AddStringSlice(prev int, key []byte, data [][]byte) int {
	off := len(t.ctrl)
	t.ensureSpace()
	base := unsafe.Pointer(unsafe.SliceData(t.ctrl))
	t.linkToPrev(prev, off)
	dataOff := len(t.data)
	t.packStringSlice(data)
	respt := (*prettyViewObjNode)(unsafe.Add(base, off))
	*respt = prettyViewObjNode{
		key:  t.packKey(key),
		kind: prettyViewKindValueStringSlice | prettyViewKind(dataOff<<32),
		misc: uint32(len(data)),
	}
	t.ctrl = unsafe.Slice((*byte)(base), off+prettyViewObjNodeSize)
	return off
}

func (t *packedTree) addAnySlice(prev int,
	key []byte,
	data []byte,
	items int,
	kind prettyViewKind,
) int {
	off := len(t.ctrl)
	t.ensureSpace()
	base := unsafe.Pointer(unsafe.SliceData(t.ctrl))
	t.linkToPrev(prev, off)
	dataOff := len(t.data)
	t.data = append(t.data, data...)
	respt := (*prettyViewObjNode)(unsafe.Add(base, off))
	*respt = prettyViewObjNode{
		key:  t.packKey(key),
		kind: kind | prettyViewKind(dataOff<<32),
		next: 0,
		misc: uint32(items),
	}
	t.ctrl = unsafe.Slice((*byte)(base), off+prettyViewObjNodeSize)
	return off
}

func (t *packedTree) addNumFullWithKind(prev int, key []byte, data uint64, kind prettyViewKind) int {
	off := len(t.ctrl)
	t.ensureSpace()
	base := unsafe.Pointer(unsafe.SliceData(t.ctrl))
	t.linkToPrev(prev, off)
	respt := (*prettyViewObjNode)(unsafe.Add(base, off))
	kindPart := (data >> 32) << 32
	miscPart := uint32(data)
	*respt = prettyViewObjNode{
		key:  t.packKey(key),
		kind: kind | prettyViewKind(kindPart),
		misc: miscPart,
	}
	t.ctrl = unsafe.Slice((*byte)(base), off+prettyViewObjNodeSize)
	return off
}

func (t *packedTree) linkToPrev(prev int, off int) {
	if prev < 0 {
		return
	}

	base := unsafe.Pointer(unsafe.SliceData(t.ctrl))
	v := (*prettyViewObjNode)(unsafe.Add(base, prev))

	if v.kind&0x1F != prettyViewKindRoot {
		// Just set prev's next if this is not an object root.
		v.next = uint32(off)
		return
	}

	if v.misc > 0 {
		// This matches a situation when a root was closed, and
		// we are adding an element next to the root, not into the group itself.
		v.next = uint32(off)
		return
	}

	// We are just after a root node meaning we are filling it.
	// Need to set up a misc to refer a child element we are adding.
	v.misc = uint32(off)
}

func packFullNum(value uint64) (kindPart uint64, miscPart uint32) {
	bytesNo := 8 - bits.LeadingZeros64(value)/8
	if bytesNo < 8 {
		return value<<8 | 1<<7, 0
	}

	return (value >> 32) << 32, uint32(value)
}

func unpackFullNum(kind prettyViewKind, misc uint32) uint64 {
	if uint64(kind)<<56>>61 != 0 {
		return uint64(kind) >> 8
	}
	return uint64(kind>>32)<<32 | uint64(misc)
}

type prettyViewKind uint64

const (
	prettyViewKindUnknown prettyViewKind = iota
	prettyViewKindRoot
	prettyViewKindValueBool     // Value is in the second byte.
	prettyViewKindValueTime     // 4 high bytes are in kind itself. 4 low bytes are in misc.
	prettyViewKindValueDuration // Same as for *Time.
	prettyViewKindValueInt
	prettyViewKindValueUint  // Same as for *Int.
	prettyViewKindValueFloat // Same as for *Time for bits of float64.
	prettyViewKindValueString
	prettyViewKindValueStringShort
	prettyViewKindValueByteSlice
	prettyViewKindValueByteSliceShort // Same as for *StringShort.
	prettyViewKindValueBoolSlice      // Boolean values are using bit masks.
	prettyViewKindValueBoolSliceShort
	prettyViewKindValueIntSlice
	prettyViewKindValueInt8Slice
	prettyViewKindValueInt16Slice
	prettyViewKindValueInt32Slice
	prettyViewKindValueInt64Slice
	prettyViewKindValueUintSlice
	prettyViewKindValueUint8Slice
	prettyViewKindValueUint16Slice
	prettyViewKindValueUint32Slice
	prettyViewKindValueUint64Slice
	prettyViewKindValueFloat32Slice
	prettyViewKindValueFloat64Slice
	prettyViewKindValueStringSlice

	// *Int note:
	//  - If 7 or fewer bytes are enough for keeping a value it is encoded right in the kind where
	//    at least one of high 3 bits of the lower byte of kind is not zero and the value is kept
	//    in 7 high bytes of the kind value.
	//    In case all these bits are zero the value is split among kind and misc, where high 4 bytes
	//    of value is kept in high 4 bytes of kind and 4 low bytes are in the misc.
	//
	// *StringShort note:
	//  - It is *StringShort code itself in the first 5 bits of kind.
	//  - If 3 high bits of the first byte of the kind are not zero, they code a length. The text is stored in the
	//    bytes 2 … 8. This means up to 7 bytes of string data.
	//  - If those bits are all zero, the length is coded in the 2nd byte of the kind. The data is placed in bytes
	//    3 … 8 of kind and 4 bytes of misc. Up to 10 bytes of string data.
	//
	// *ArrayBoolShort note:
	//  - The length of the array is in the bits 6 … 8 of the low byte of kind + 4 low bits of the second byte of kind.
	//    This means we can address up to 4 + 6*8 + 4*8 = 84 long bool arrays.
)

type prettyViewObjNode struct {
	// key can handle either offset placed at the higher part of this number, or a short word up to
	// 8 characters. Shorter words with 7 characters or fewer are treated as zero-terminated strings.
	// The check is trivial: uint(key) != 0 means it is a packed word. It is an offset otherise.
	key uint64
	// kind keeps/refers both a kind of value and a value itself as described in prettyViewKind comments.
	kind prettyViewKind
	next uint32
	// misc has various usage depending on the kind. It can be:
	//  - A part of short payload.
	//  - Length of string, bytes or array.
	//  - A link to a first child node of a group.
	misc uint32
}

const prettyViewObjNodeSize = int(unsafe.Sizeof(prettyViewObjNode{}))

var prettyViewObjNodePlaceholder = [prettyViewObjNodeSize]byte{}

type prettyViewArray struct {
	len  uint64
	kind prettyViewKind // limited to byte, int, uint, float and string types.
	ptr  uint64
}

const prettyViewArraySize = unsafe.Sizeof(prettyViewArray{})

type prettyViewString struct {
	len uint64
	ptr uint64
}

const prettyViewStringSize = unsafe.Sizeof(prettyViewString{})

type prettyViewScalar struct {
	val uint64
}

const prettyViewScalarSize = unsafe.Sizeof(prettyViewScalar{})

func init() {
	guard := [1]struct{}{}
	_ = guard[unsafe.Sizeof(prettyViewArray{})-24]
	_ = guard[unsafe.Sizeof(prettyViewString{})-16]
	_ = guard[unsafe.Sizeof(prettyViewScalar{})-8]
}

func (k prettyViewKind) String() string {
	switch k {
	case prettyViewKindRoot:
		return "root"
	case prettyViewKindValueBool:
		return "bool"
	case prettyViewKindValueTime:
		return "time"
	case prettyViewKindValueDuration:
		return "duration"
	case prettyViewKindValueInt:
		return "int"
	case prettyViewKindValueUint:
		return "uint"
	case prettyViewKindValueFloat:
		return "float"
	case prettyViewKindValueString, prettyViewKindValueStringShort:
		return "string"
	case prettyViewKindValueByteSlice, prettyViewKindValueByteSliceShort:
		return "[]byte"
	case prettyViewKindValueBoolSlice, prettyViewKindValueBoolSliceShort:
		return "[]bool"
	case prettyViewKindValueIntSlice:
		return "[]int"
	case prettyViewKindValueInt8Slice:
		return "[]int8"
	case prettyViewKindValueInt16Slice:
		return "[]int16"
	case prettyViewKindValueInt32Slice:
		return "[]int32"
	case prettyViewKindValueInt64Slice:
		return "[]int64"
	case prettyViewKindValueUintSlice:
		return "[]uint"
	case prettyViewKindValueUint8Slice:
		return "[]uint8"
	case prettyViewKindValueUint16Slice:
		return "[]uint16"
	case prettyViewKindValueUint32Slice:
		return "[]uint32"
	case prettyViewKindValueUint64Slice:
		return "[]uint64"
	case prettyViewKindValueFloat32Slice:
		return "[]float32"
	case prettyViewKindValueFloat64Slice:
		return "[]float64"
	case prettyViewKindValueStringSlice:
		return "[]string"
	default:
		// Используем strconv для формирования fallback-строки без fmt
		return "pretty-view-kind-value-unknown(" + strconv.FormatUint(uint64(k), 10) + ")"
	}
}

func (k prettyViewKind) Pure() prettyViewKind {
	return k & 0x1F
}
