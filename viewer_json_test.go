package blog

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"hash/crc32"
	"math"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/alecthomas/assert/v2"

	"github.com/sirkon/blog/internal/core"
)

func TestNewJSONWriter(t *testing.T) {
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
		Int            int       `json:"int"`
		Int8           int8      `json:"int8"`
		Int16          int16     `json:"int16"`
		Int32          int32     `json:"int32"`
		Int64          int64     `json:"int64"`
		Uint           uint      `json:"uint"`
		Uint8          uint8     `json:"uint8"`
		Uint16         uint16    `json:"uint16"`
		Uint32         uint32    `json:"uint32"`
		Uint64         uint64    `json:"uint64"`
		Float32        float32   `json:"float32"`
		Float64        float64   `json:"float64"`
		StrEmpty       string    `json:"string_empty"`
		StrVeryShort   string    `json:"string_very_short"`
		StrShort       string    `json:"string_short"`
		String         string    `json:"string_long"`
		BytesEmpty     []byte    `json:"bytes_empty"`
		Bytes          []byte    `json:"bytes"`

		IntSliceEmpty []int     `json:"ints_empty"`
		Ints          []int     `json:"ints"`
		Int8s         []int8    `json:"int8s"`
		Int16s        []int16   `json:"int16s"`
		Int32s        []int32   `json:"int32s"`
		Int64s        []int64   `json:"int64s"`
		Uints         []uint    `json:"uints"`
		Uint8s        []uint8   `json:"uint8s"`
		Uint16s       []uint16  `json:"uint16s"`
		Uint32s       []uint32  `json:"uint32s"`
		Uint64s       []uint64  `json:"uint64s"`
		Flt32s        []float32 `json:"float32s"`
		Flt64s        []float64 `json:"float64s"`
		Strs          []string  `json:"strings"`
		BoolsEmpty    []bool    `json:"bools_empty"`
		BoolsShort    []bool    `json:"bools_short"`
		Bools         []bool    `json:"bools"`

		GroupEmpty struct{}  `json:"group_empty"`
		GroupFlat  GroupFlat `json:"group_flat"`
		GroupTree  GroupTree `json:"group_tree"`
		Err        Error     `json:"err"`
		End        bool      `json:"end"`
	}

	sample := &Sample{
		BoolTrue:     true,
		BoolFalse:    false,
		Time:         time.Now(),
		Duration:     dur.String(),
		Int:          -1,
		Int8:         -2,
		Int16:        -3,
		Int32:        -4,
		Int64:        -5,
		Uint:         math.MaxUint64,
		Uint8:        1,
		Uint16:       2,
		Uint32:       3,
		Uint64:       math.MaxUint64,
		Float32:      0,
		Float64:      math.Pi,
		StrEmpty:     "",
		StrVeryShort: "12345",
		StrShort:     "123456789",
		String:       "abcdefghijklmnopqrstuvwxyz",
		BytesEmpty:   nil,
		Bytes:        []byte{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19},
		IntSliceEmpty: []int{},
		Ints:          []int{math.MinInt, 100000000, math.MaxInt},
		Int8s:         []int8{math.MinInt8, 100, math.MaxInt8},
		Int16s:        []int16{math.MinInt16, 400, math.MaxInt16},
		Int32s:        []int32{math.MinInt32, 10000, math.MaxInt32},
		Int64s:        []int64{math.MinInt64, math.MaxInt64},
		Uints:         []uint{0, 100, 200, math.MaxUint64},
		Uint8s:        []uint8{0, 100, 222, math.MaxUint8},
		Uint16s:       []uint16{0, 100, 300, 999, math.MaxUint16},
		Uint32s:       []uint32{0, 100, 400, 9999, math.MaxUint32},
		Uint64s:       []uint64{0, 100, 500, 139999999, math.MaxUint64},
		Flt32s:        []float32{1.25, 2.5, 3.75},
		Flt64s:        []float64{math.Pi, math.E, math.Phi, math.Ln10},
		Strs:          []string{"ghijklmnop", "qrstuvwxyz"},
		BoolsEmpty:    []bool{},
		BoolsShort:    []bool{true, false},
		Bools:         slices.Repeat([]bool{true, false, true, true}, 22),
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
		Err: Error{
			Text: "wrap: foreign wrap: error",
			Context: map[string]map[string]any{
				"NEW: error": {
					"flag": true,
				},
				"WRAP: wrap": {
					"text": "this is fun",
					"extra": []any{1, 2, 3},
				},
				"CTX": {
					"ctxtext": "ctx",
				},
			},
		},
		End: true,
	}

	err := error(core.NewError("error").Bool("flag", true))
	err = fmt.Errorf("foreign wrap: %w", err)
	err = core.WrapError(err, "wrap").Str("text", "this is fun")
	ctx := context.Background()

	var sb strings.Builder
	w := NewJSONWriter(&sb)

	logger, lerr := NewLogger(w, core.OptionLogLocations())
	if lerr != nil {
		t.Fatal(core.WrapError(lerr, "create logger"))
	}

	logger.Error(ctx, "test message",
		core.Bool("bool_true", sample.BoolTrue),
		core.Bool("bool_false", sample.BoolFalse),
		core.Time("time", sample.Time),
		core.Duration("duration", dur),
		core.Int("int", sample.Int),
		core.Int8("int8", sample.Int8),
		core.Int16("int16", sample.Int16),
		core.Int32("int32", sample.Int32),
		core.Int64("int64", sample.Int64),
		core.Uint("uint", sample.Uint),
		core.Uint8("uint8", sample.Uint8),
		core.Uint16("uint16", sample.Uint16),
		core.Uint32("uint32", sample.Uint32),
		core.Uint64("uint64", sample.Uint64),
		core.Flt32("float32", sample.Float32),
		core.Flt64("float64", sample.Float64),
		core.Str("string_empty", sample.StrEmpty),
		core.Str("string_very_short", sample.StrVeryShort),
		core.Str("string_short", sample.StrShort),
		core.Str("string_long", sample.String),
		core.Bytes("bytes_empty", sample.BytesEmpty),
		core.Bytes("bytes", sample.Bytes),
		core.Ints("ints_empty", sample.IntSliceEmpty),
		core.Ints("ints", sample.Ints),
		core.Int8s("int8s", sample.Int8s),
		core.Int16s("int16s", sample.Int16s),
		core.Int32s("int32s", sample.Int32s),
		core.Int64s("int64s", sample.Int64s),
		core.Uints("uints", sample.Uints),
		core.Uint8s("uint8s", sample.Uint8s),
		core.Uint16s("uint16s", sample.Uint16s),
		core.Uint32s("uint32s", sample.Uint32s),
		core.Uint64s("uint64s", sample.Uint64s),
		core.Flt32s("float32s", sample.Flt32s),
		core.Flt64s("float64s", sample.Flt64s),
		core.Strs("strings", sample.Strs),
		core.Bools("bools_empty", sample.BoolsEmpty),
		core.Bools("bools_short", sample.BoolsShort),
		core.Bools("bools", sample.Bools),
		core.Group("group_empty"),
		core.Group("group_flat",
			core.Str("text", sample.GroupFlat.Text),
			core.Int("weight", sample.GroupFlat.Weight),
		),
		core.Group("group_tree",
			core.Int("depth", sample.GroupTree.Depth),
			core.Group("group",
				core.Str("text", sample.GroupTree.Group.Text),
				core.Int("weight", sample.GroupTree.Group.Weight),
			),
			core.Str("rest", sample.GroupTree.Rest),
		),
		core.Err(err),
		core.Bool("end", true),
	)

	line := sb.String()
	if !strings.HasSuffix(line, "\n") {
		t.Fatalf("output must end with a new line: %q", line)
	}

	var report struct {
		Time  time.Time `json:"time"`
		Level string    `json:"level"`
		Loc   *struct {
			File string `json:"file"`
			Line int    `json:"line"`
		} `json:"loc,omitempty"`
		Msg string `json:"msg"`
		Sample
	}
	if err := json.Unmarshal([]byte(line), &report); err != nil {
		t.Fatal(core.WrapError(err, "unmarshal sample output"))
	}

	if report.Time.IsZero() {
		t.Error("expected filled time")
	}
	if report.Level != "ERROR" {
		t.Errorf("expected level ERROR, got %s", report.Level)
	}
	if report.Msg != "test message" {
		t.Errorf("expected msg test message, got %s", report.Msg)
	}
	if report.Loc == nil {
		t.Error("expected loc, got nothing")
	} else if report.Loc.Line <= 0 {
		t.Errorf("expected valid loc line, got %d", report.Loc.Line)
	}

	// Sample values roundtrip.
	assert.Equal(t, *sample, report.Sample)

	// Every data field must be packed without spaces.
	if line != line[:len(line)-1] || strings.Contains(line[:len(line)-1], " ") || strings.Contains(line[:len(line)-1], "\t") {
		t.Fatalf("output must be packed without whitespace: %q", line)
	}
}

func TestJSONWriterInvalidLevel(t *testing.T) {
	var sb strings.Builder
	w := NewJSONWriter(&sb)

	// Hand-craft a record with an unknown level byte (255) in place of the level.
	record := make([]byte, 0, 64)
	record = binary.LittleEndian.AppendUint16(record, core.Version)
	record = binary.LittleEndian.AppendUint64(record, uint64(time.Now().UnixNano()))
	record = append(record, 255) // level
	record = append(record, 0)   // no location
	record = binary.AppendUvarint(record, uint64(len("fake message")))
	record = append(record, "fake message"...)

	checksum := crc32.Checksum(record, crc32.MakeTable(crc32.Castagnoli))
	line := make([]byte, 0, 64)
	line = append(line, 0xFF)
	line = binary.LittleEndian.AppendUint32(line, checksum)
	line = append(line, 0xFE)
	line = binary.AppendUvarint(line, uint64(len(record)))
	line = append(line, record...)

	if _, err := w.Write(line); err != nil {
		t.Fatal(err)
	}

	out := strings.TrimSuffix(sb.String(), "\n")
	var report struct {
		Time  string `json:"time"`
		Level string `json:"level"`
		Msg   string `json:"msg"`
	}
	if err := json.Unmarshal([]byte(out), &report); err != nil {
		t.Fatal(err)
	}
	if report.Level != "INVALID(255)" {
		t.Fatalf("expected INVALID(255), got %s", report.Level)
	}
	if report.Msg != "fake message" {
		t.Fatalf("expected fake message, got %s", report.Msg)
	}
}