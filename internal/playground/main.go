package main

import (
	"context"
	"fmt"
	"io"
	"math"
	"os"
	"runtime/debug"
	"time"

	"github.com/sirkon/blog"
	"github.com/sirkon/blog/beer"
	"github.com/sirkon/blog/internal/core"
)

func main() {
	logWriter := blog.NewPrettyWriter(os.Stdout)
	if len(os.Args) > 1 {
		switch os.Args[1] {
		case "light":
			logWriter.WithLightTerminal()
		case "dark":
			logWriter.WithDarkTerminal()
		}
	}
	log, err := core.NewLogger(
		logWriter,
		// blog.NewRawJSONWriter(os.Stdout),
		blog.OptionLogLocations(),
	)
	if err != nil {
		panic(err)
	}
	core.InsertLocationsOn()
	defer func() {
		r := recover()
		if r == nil {
			return
		}
		info := blog.LogPanicInfo(r)
		blog.LogPanic(context.Background(), log, debug.Stack(), info)
	}()

	start := time.Now()
	err = beer.Wrap(io.EOF, "wrap 1").Str("tag", "tag1")
	err = beer.Just(err).Int("key", 12)
	err = beer.Wrap(err, "wrap 2").Bool("bool", true)
	err = fmt.Errorf("foreign wrap 1: %w", err)
	err = beer.Wrap(err, "wrap 3").Str("tag", `"quoted tag value"`).Bytes("bytes", []byte{1, 2, 3})
	err = fmt.Errorf("foreign wrap 2: %w", err)

	log.Trace(nil, "trace check")
	log.Debug(nil, "debug check")
	log.Info(context.Background(), "no errors",
		blog.Str("text", "Hello World!"),
		blog.Int("int", 12),
	)
	log.Warn(nil, "warning check", blog.Err(io.EOF))
	log.Error(context.Background(),
		"test",
		blog.Str("text", "Hello World!"),
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
	)
	err = beer.New("this is an error").
		Bytes("bytes", []byte{1, 2, 3}).
		Str("text-bytes", "Hello World!")
	err = beer.Wrap(err, "check error").
		Int("count", 333).
		Bool("is-wrap-layer", true)
	err = beer.Just(err).
		Flt64("pi", math.Pi).
		Flt64("e", math.E)
	log.Error(nil, "failed to do something", blog.Err(err))

	//panic(0)
}
