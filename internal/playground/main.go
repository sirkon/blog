package main

import (
	"context"
	"math"
	"os"
	"time"

	"github.com/sirkon/blog"
)

func main() {
	log, err := blog.NewLogger(
		blog.NewViewWriteSyncer(blog.NewHumanView(), os.Stderr),
		blog.OptionLogLocations(),
	)
	if err != nil {
		panic(err)
	}

	start := time.Now()
	log.Info(context.Background(),
		"test",
		blog.Str("text", "Hello world!"),
		blog.Time("time", start),
		blog.Group("math-constants",
			blog.Flt64("pi", math.Pi),
			blog.Flt64("e", math.E),
		),
		blog.Duration("duration", time.Since(start)),
	)
}
