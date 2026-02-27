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
		blog.NewViewWriteSyncer(blog.NewHumanView(), os.Stdout),
		core.OptionLogLocations(),
	)
	if err != nil {
		panic(err)
	}
	core.InsertLocationsOn()

	start := time.Now()
	err = beer.Wrap(io.EOF, "check error").Str("tag", "tag value")
	err = beer.Just(err).Int("key", 12)
	err = beer.Wrap(err, "another check").Bool("bool", true)
	err = fmt.Errorf("top check: %w", err)
	log.Info(context.Background(),
		"test",
		blog.Str("text", "Hello world!"),
		blog.Time("time", start),
		blog.Group("math-constants",
			blog.Flt64("pi", math.Pi),
			blog.Flt64("e", math.E),
		),
		blog.Duration("duration", time.Since(start)),
		blog.Err(io.EOF),
		blog.Strs("words", []string{"I", "am", "waiting", "for", "the", "spring"}),
		blog.Error("err-with-ctx", err),
	)
}
