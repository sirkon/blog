package main

import (
	"context"
	"fmt"
	"io"
	"math"
	"os"
	"time"

	"github.com/sirkon/blog"
	"github.com/sirkon/blog/beer"
	"github.com/sirkon/blog/internal/core"
)

func main() {
	log, err := core.NewLogger(
		blog.NewPrettyWriter(os.Stdout),
		//blog.NewRawJSONWriter(os.Stdout),
	)
	if err != nil {
		panic(err)
	}
	core.InsertLocationsOn()

	start := time.Now()
	err = beer.Wrap(io.EOF, "wrap 1").Str("tag", "tag1")
	err = beer.Just(err).Int("key", 12)
	err = beer.Wrap(err, "wrap 2").Bool("bool", true)
	err = fmt.Errorf("foreign wrap 1: %w", err)
	err = beer.Wrap(err, "wrap 3").Str("tag", `"quoted tag value"`).Bytes("bytes", []byte{1, 2, 3})
	err = fmt.Errorf("foreign wrap 2: %w", err)

	log.Info(context.Background(),
		"test",
		blog.Str("text", "Hello world!"),
		blog.Time("time", start),
		blog.Group("math",
			blog.Flt64("pi", math.Pi),
			blog.Flt64("e", math.E),
			blog.Flt64s("combo", []float64{math.Pi, math.E}),
		),
		blog.Duration("duration", time.Since(start)),
		blog.Err(io.EOF),
		blog.Strs("words", []string{"I", "am", "waiting", "for", "the", "spring"}),
		blog.Error("err-with-ctx", err),
		blog.Bytes("bytes", []byte{1, 2, 3, 4, 5, 6}),
		blog.Ints("ints", []int{1, 2, 3, 4, 5, 6}),
		blog.Int8s("int8s", []int8{1, 2, 3, 4, 5, 6}),
		blog.Int16s("int16s", []int16{1, 2, 3, 4, 5, 6}),
		blog.Int32s("int32s", []int32{1, 2, 3, 4, 5, 6}),
		blog.Int64s("int64s", []int64{1, 2, 3, 4, 5, 6}),
		blog.Uints("uints", []uint{1, 2, 3, 4, 5, 6}),
		blog.Uint8s("uint8s", []uint8{1, 2, 3, 4, 5, 6}),
		blog.Uint16s("uint16s", []uint16{1, 2, 3, 4, 5, 6}),
		blog.Uint32s("uint32s", []uint32{1, 2, 3, 4, 5, 6}),
		blog.Uint64s("uint64s", []uint64{1, 2, 3, 4, 5, 6}),
		blog.Flt32s("float32s", []float32{1.25, 2.5}),
		blog.Flt64s("float64s", []float64{math.Pi, math.E}),
	)
}
