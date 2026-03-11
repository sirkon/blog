package blog

import (
	"bytes"
	"math"
	"math/bits"
	"strconv"
	"strings"
	"testing"
	"time"
	"unsafe"

	"github.com/alecthomas/assert/v2"
)

func TestNodes(t *testing.T) {
	newTree := func() *packedTree {
		return &packedTree{}
	}
	byt := func(s string) []byte {
		return []byte(s)
	}
	getNode := func(t *packedTree, off int) *prettyViewNode {
		return (*prettyViewNode)(unsafe.Add(unsafe.Pointer(unsafe.SliceData(t.ctrl)), 0))
	}

	t.Run("key unpack", func(t *testing.T) {
		for i := range 100 {
			t.Run("key-length-"+strconv.Itoa(i), func(t *testing.T) {
				tree := newTree()
				tree.AddBool(-1, bytes.Repeat([]byte{'x'}, i+1), true)
				node := getNode(tree, 0)

				key := tree.unpackKey(node)
				assert.Equal(t, strings.Repeat("x", i+1), key, "check key unpack for length "+strconv.Itoa(i+1))
			})
		}
	})

	t.Run("bool", func(t *testing.T) {
		t.Run("true", func(t *testing.T) {
			tree := newTree()
			tree.AddBool(-1, byt("value"), true)
			node := getNode(tree, 0)

			assert.Equal(t, prettyViewKindValueBool, node.kind.Pure())
			assert.True(t, node.kind>>8 != 0, "checks if kind represents boolean true")
		})

		t.Run("false", func(t *testing.T) {
			tree := newTree()
			tree.AddBool(-1, byt("value"), false)
			node := getNode(tree, 0)

			assert.Equal(t, prettyViewKindValueBool, node.kind.Pure())
			assert.True(t, node.kind>>8 == 0, "checks if kind represents boolean false")
		})
	})

	t.Run("time", func(t *testing.T) {
		tree := newTree()
		timeThen := time.Now()
		tree.AddTime(-1, byt("key"), timeThen)
		node := getNode(tree, 0)

		assert.Equal(t, prettyViewKindValueTime, node.kind.Pure())

		timeValue := unpackFullNum(node.kind, node.misc)
		timeGot := time.Unix(0, int64(timeValue))

		assert.Equal(t, timeThen, timeGot)
	})

	t.Run("duration", func(t *testing.T) {
		timeThen := time.Now()
		tree := newTree()
		dur := time.Now().Add(time.Second).Sub(timeThen)
		tree.AddDuration(-1, byt("key"), dur)
		node := getNode(tree, 0)

		assert.Equal(t, prettyViewKindValueDuration, node.kind.Pure())
		durValue := unpackFullNum(node.kind, node.misc)
		durGot := time.Duration(durValue)
		assert.Equal(t, dur, durGot, "checks if duration was represented correctly")
	})

	t.Run("int", func(t *testing.T) {
		for i := range 8 {
			v := uint64(1 << (i * 8))
			length := 8 - bits.LeadingZeros64(v)/8
			t.Run(strconv.Itoa(length)+" bytes int", func(t *testing.T) {
				tree := newTree()
				v := 1 << (i * 8)
				tree.AddInt(-1, byt("value"), int64(v))
				node := getNode(tree, 0)

				assert.Equal(t, prettyViewKindValueInt, node.kind.Pure())
				value := unpackFullNum(node.kind, node.misc)
				assert.Equal(t, v, int(value), "checks if value was represented correctly")
			})
		}
	})

	t.Run("uint", func(t *testing.T) {
		for i := range 8 {
			v := uint64(1 << (i * 8))
			length := 8 - bits.LeadingZeros64(v)/8
			t.Run(strconv.Itoa(length)+" bytes int", func(t *testing.T) {
				tree := newTree()
				tree.AddUint(-1, byt("value"), v)
				node := getNode(tree, 0)

				assert.Equal(t, prettyViewKindValueUint, node.kind.Pure())
				value := unpackFullNum(node.kind, node.misc)
				assert.Equal(t, v, value, "checks if value was represented correctly")
			})
		}
	})

	t.Run("float", func(t *testing.T) {
		tree := newTree()
		tree.AddFloat(-1, byt("value"), math.Pi)
		node := getNode(tree, 0)

		assert.Equal(t, prettyViewKindValueFloat, node.kind.Pure())
		value := math.Float64frombits(unpackFullNum(node.kind, node.misc))
		assert.Equal(t, math.Pi, value)
	})

	t.Run("string", func(t *testing.T) {
		t.Run("7 letters", func(t *testing.T) {
			tree := newTree()
			value := "1234567"
			tree.AddString(-1, byt("value"), []byte(value))
			node := getNode(tree, 0)

			assert.Equal(t, prettyViewKindValueStringShort, node.kind.Pure())
			var shortPlace uint64
			var longPlace [16]byte
			check := string(unpackShortStringValue(node, &shortPlace, longPlace))
			assert.Equal(t, value, check, "checks if string value was represented correctly")
		})

		t.Run("9 letters", func(t *testing.T) {
			tree := newTree()
			value := "123456789"
			tree.AddString(-1, byt("value"), []byte(value))
			node := getNode(tree, 0)

			assert.Equal(t, prettyViewKindValueStringShort, node.kind.Pure())
			var shortPlace uint64
			var longPlace [16]byte
			check := string(unpackShortStringValue(node, &shortPlace, longPlace))
			assert.Equal(t, value, check, "checks if string value was represented correctly")
		})

		t.Run("11 letters", func(t *testing.T) {
			tree := newTree()
			value := "0123456789a"
			tree.AddString(-1, byt("value"), []byte(value))
			node := getNode(tree, 0)

			assert.Equal(t, prettyViewKindValueString, node.kind.Pure())
			off := node.kind >> 32
			check := unsafe.String(
				(*byte)(unsafe.Add(unsafe.Pointer(unsafe.SliceData(tree.data)), off)),
				node.misc,
			)
			assert.Equal(t, value, check, "checks if string value was represented correctly")

		})
	})

	t.Run("[]byte", func(t *testing.T) {
		t.Run("7 bytes", func(t *testing.T) {
			tree := newTree()
			value := []byte{1, 2, 3, 4, 5, 6, 7}
			tree.AddBytes(-1, byt("value"), value)
			node := getNode(tree, 0)

			assert.Equal(t, prettyViewKindValueByteSliceShort, node.kind.Pure())
			var shortPlace uint64
			var longPlace [16]byte
			check := unpackShortStringValue(node, &shortPlace, longPlace)
			assert.Equal(t, value, check, "checks if string value was represented correctly")
		})

		t.Run("9 bytes", func(t *testing.T) {
			tree := newTree()
			value := []byte{1, 2, 3, 4, 5, 6, 7, 8, 9}
			tree.AddBytes(-1, byt("value"), []byte(value))
			node := getNode(tree, 0)

			assert.Equal(t, prettyViewKindValueByteSliceShort, node.kind.Pure())
			var shortPlace uint64
			var longPlace [16]byte
			check := unpackShortStringValue(node, &shortPlace, longPlace)
			assert.Equal(t, value, check, "checks if string value was represented correctly")
		})

		t.Run("11 bytes", func(t *testing.T) {
			tree := newTree()
			value := []byte{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11}
			tree.AddBytes(-1, byt("value"), []byte(value))
			node := getNode(tree, 0)

			assert.Equal(t, prettyViewKindValueByteSlice, node.kind.Pure())
			off := node.kind >> 32
			check := unsafe.Slice(
				(*byte)(unsafe.Add(unsafe.Pointer(unsafe.SliceData(tree.data)), off)),
				node.misc,
			)
			assert.Equal(t, value, check, "checks if string value was represented correctly")

		})
	})

}
