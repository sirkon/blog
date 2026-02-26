package main

import (
	"bytes"
	"context"
	"fmt"
	"math"
	"time"

	"github.com/sirkon/blog"
)

func main() {
	var buf bytes.Buffer
	log, err := blog.NewLogger(&buf, blog.OptionLogLocations())
	if err != nil {
		panic(err)
	}

	log.Info(context.Background(),
		"test",
		blog.Str("text", "Hello world!"),
		blog.Time("time", time.Now()),
		blog.Group("math-constants",
			blog.Flt64("pi", math.Pi),
			blog.Flt64("e", math.E),
		),
	)

	fmt.Println(buf.Bytes())
	fmt.Println(buf.String())
}
