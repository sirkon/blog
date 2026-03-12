package blog

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"math"
	"os"
	"slices"
	"testing"
	"time"

	"github.com/alecthomas/assert/v2"

	"github.com/sirkon/blog/internal/core"
)

func TestNewPrettyWriter(t *testing.T) {
	dur := time.Second * 3 / 2
	core.InsertLocationsOff()

	type GroupFlat struct {
		Text   string `json:"text"`
		Weight int    `json:"weight"`
	}
	type GroupTree struct {
		Depth int       `json:"depth"`
		Group GroupFlat `json:"group"`
		Rest  string    `json:"rest"`
	}
	type Error struct {
		Text    string                    `json:"@text"`
		Context map[string]map[string]any `json:"@context"`
	}

	type Sample struct {
		BoolTrue       bool      `json:"bool_true"`
		BoolFalse      bool      `json:"bool_false"`
		Time           time.Time `json:"time"`
		Duration       string    `json:"duration"`
		IntShort       int       `json:"int_short"`
		Int            int       `json:"int"`
		Int8           int8      `json:"int8"`
		Int16          int16     `json:"int16"`
		Int32          int32     `json:"int32"`
		Int64Short     int64     `json:"int64_short"`
		Int64          int64     `json:"int64"`
		UintShort      uint      `json:"uint_short"`
		Uint           uint      `json:"uint"`
		Uint8          uint8     `json:"uint8"`
		Uint16         uint16    `json:"uint16"`
		Uint32         uint32    `json:"uint32"`
		Uint64Short    uint64    `json:"uint64_short"`
		Uint64         uint64    `json:"uint64"`
		Float32        float32   `json:"float32"`
		Float64        float64   `json:"float64"`
		StrEmpty       string    `json:"string_empty"`
		StrVeryShort   string    `json:"string_very_short"`
		StrShort       string    `json:"string_short"`
		String         string    `json:"string"`
		BytesEmpty     []byte    `json:"bytes_empty"`
		BytesVeryShort []byte    `json:"bytes_very_short"`
		BytesShort     []byte    `json:"bytes_short"`
		Bytes          []byte    `json:"bytes"`

		IntSliceEmpty        []int     `json:"int_slice_empty"`
		IntSlice             []int     `json:"ints"`
		Int8Slice            []int8    `json:"int8s"`
		Int16Slice           []int16   `json:"int16s"`
		Int32Slice           []int32   `json:"int32s"`
		Int64Slice           []int64   `json:"int64s"`
		UintSlice            []uint    `json:"uints"`
		Uint8Slice           []uint8   `json:"uint8s"`
		Uint16Slice          []uint16  `json:"uint16s"`
		Uint32Slice          []uint32  `json:"uint32s"`
		Uint64Slice          []uint64  `json:"uint64s"`
		Float32Slice         []float32 `json:"float32s"`
		Float64Slice         []float64 `json:"float64s"`
		StringSlice          []string  `json:"strings"`
		BoolSliceEmpty       []bool    `json:"bools_empty"`
		BoolSliceShort       []bool    `json:"bools_short"`
		BoolSliceShortLarger []bool    `json:"bools_short_larger"`
		BoolSlice            []bool    `json:"bools"`
		GroupEmpty           struct{}  `json:"group_empty"`
		GroupFlat            GroupFlat `json:"group_flat"`
		GroupTree            GroupTree `json:"group_tree"`
		End                  bool      `json:"end"`
		Err                  Error     `json:"err"`
		Error                string    `json:"error"`
	}

	err := error(core.NewError("error").Bool("flag", true))
	err = fmt.Errorf("foreign wrap: %w", err)
	err = core.WrapError(err, "wrap").Str("text", "this is fun")
	err = core.JustError(err).Str("ctxtext", "ctx")
	sample := &Sample{
		BoolTrue:             true,
		BoolFalse:            false,
		Time:                 time.Now(),
		Duration:             dur.String(),
		IntShort:             100,
		Int:                  -1,
		Int8:                 -2,
		Int16:                -3,
		Int32:                -4,
		Int64Short:           1,
		Int64:                -5,
		UintShort:            101,
		Uint:                 math.MaxUint64,
		Uint8:                1,
		Uint16:               2,
		Uint32:               3,
		Uint64Short:          0,
		Uint64:               math.MaxUint64,
		Float32:              0,
		Float64:              math.Pi,
		StrEmpty:             "",
		StrVeryShort:         "12345",
		StrShort:             "123456789",
		String:               "abcdefghijklmnopqrstuvwxyz",
		BytesEmpty:           nil,
		BytesVeryShort:       []byte{1, 2, 3},
		BytesShort:           []byte{1, 2, 3, 4, 5, 6, 7, 8},
		Bytes:                []byte{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19},
		IntSliceEmpty:        []int{},
		IntSlice:             []int{math.MinInt, 100000000, math.MaxInt},
		Int8Slice:            []int8{math.MinInt8, 100, math.MaxInt8},
		Int16Slice:           []int16{math.MinInt16, 400, math.MaxInt16},
		Int32Slice:           []int32{math.MinInt32, 10000, math.MaxInt32},
		Int64Slice:           []int64{math.MinInt64, math.MaxInt64},
		UintSlice:            []uint{0, 100, 200, math.MaxUint64},
		Uint8Slice:           []uint8{0, 100, 222, math.MaxUint8},
		Uint16Slice:          []uint16{0, 100, 300, 999, math.MaxUint16},
		Uint32Slice:          []uint32{0, 100, 400, 9999, math.MaxUint32},
		Uint64Slice:          []uint64{0, 100, 500, 139999999, math.MaxUint64},
		Float32Slice:         []float32{1.25, 2.5, 3.75},
		Float64Slice:         []float64{math.Pi, math.E, math.Phi, math.Ln10},
		StringSlice:          []string{"ghijklmnop", "qrstuvwxyz"},
		BoolSliceEmpty:       []bool{},
		BoolSliceShort:       []bool{true, false},
		BoolSliceShortLarger: slices.Repeat([]bool{true, true, false}, 22),
		BoolSlice:            slices.Repeat([]bool{true, false, true, true}, 22),
		GroupFlat: GroupFlat{
			Text:   "group text",
			Weight: 1,
		},
		GroupTree: GroupTree{
			Depth: 2,
			Group: GroupFlat{
				Text:   "subgroup",
				Weight: 100,
			},
			Rest: "rest",
		},
		End: true,
		Err: Error{
			Text: "wrap: foreign wrap: error",
			Context: map[string]map[string]any{
				"NEW: error": {
					//"@location": curFile + ":96",
					"flag": true,
				},
				"WRAP: wrap": {
					//"@location": curFile + ":98",
					"text": "this is fun",
				},
				"CTX": {
					//"@location": curFile + ":99",
					"ctxtext": "ctx",
				},
			},
		},
		Error: "EOF",
	}

	w := NewPrettyWriter(os.Stdout)
	logger, lerr := NewLogger(w, core.OptionLogLocations())
	if lerr != nil {
		t.Fatal(core.WrapError(lerr, "create logger"))
	}

	logger.Error(context.Background(), "test",
		core.Bool("bool_true", sample.BoolTrue),
		core.Bool("bool_false", sample.BoolFalse),
		core.Time("time", sample.Time),
		core.Duration("duration", dur),
		core.Int("int_short", sample.IntShort),
		core.Int("int", sample.Int),
		core.Int8("int8", sample.Int8),
		core.Int16("int16", sample.Int16),
		core.Int32("int32", sample.Int32),
		core.Int64("int64_short", sample.Int64Short),
		core.Int64("int64", sample.Int64),
		core.Uint("uint_short", sample.UintShort),
		core.Uint("uint", sample.Uint),
		core.Uint8("uint8", sample.Uint8),
		core.Uint16("uint16", sample.Uint16),
		core.Uint32("uint32", sample.Uint32),
		core.Uint64("uint64_short", sample.Uint64Short),
		core.Uint64("uint64", sample.Uint64),
		core.Flt32("float32", sample.Float32),
		core.Flt64("float64", sample.Float64),
		core.Str("string_empty", sample.StrEmpty),
		core.Str("string_very_short", sample.StrVeryShort),
		core.Str("string_short", sample.StrShort),
		core.Str("string", sample.String),
		core.Bytes("bytes_empty", sample.BytesEmpty),
		core.Bytes("bytes_very_short", sample.BytesVeryShort),
		core.Bytes("bytes_short", sample.BytesShort),
		core.Bytes("bytes", sample.Bytes),

		core.Ints("int_slice_empty", sample.IntSliceEmpty),
		core.Ints("ints", sample.IntSlice),
		core.Int8s("int8s", sample.Int8Slice),
		core.Int16s("int16s", sample.Int16Slice),
		core.Int32s("int32s", sample.Int32Slice),
		core.Int64s("int64s", sample.Int64Slice),
		core.Uints("uints", sample.UintSlice),
		core.Uint8s("uint8s", sample.Uint8Slice),
		core.Uint16s("uint16s", sample.Uint16Slice),
		core.Uint32s("uint32s", sample.Uint32Slice),
		core.Uint64s("uint64s", sample.Uint64Slice),
		core.Flt32s("float32s", sample.Float32Slice),
		core.Flt64s("float64s", sample.Float64Slice),
		core.Strs("strings", sample.StringSlice),

		core.Bools("bools_empty", sample.BoolSliceEmpty),
		core.Bools("bools_short", sample.BoolSliceShort),
		core.Bools("bools_short_larger", sample.BoolSliceShortLarger),
		core.Bools("bools", sample.BoolSlice),

		core.Group("group_empty"),
		core.Group("group_flat", core.Str("text", "group text"), core.Int("weight", 1)),
		core.Group("group_tree",
			core.Int("depth", 2),
			core.Group("group", core.Str("text", "subgroup"), core.Int("weight", 100)),
			core.Str("rest", "rest"),
		),

		core.Bool("end", true),
		core.Err(err),
		core.ErrorAttr("error", io.EOF),
	)
	fmt.Println(len(w.view.tree.ctrl), cap(w.view.tree.ctrl), w.view.tree.clen)

	w.buf = w.buf[:0]
	w.browseCtrl()
	w.walkJSON()

	var got Sample
	if err := json.Unmarshal(w.buf, &got); err != nil {
		t.Fatal(core.WrapError(err, "unmarshal sample output"))
	}

	assert.Equal(t, *sample, got)
}
