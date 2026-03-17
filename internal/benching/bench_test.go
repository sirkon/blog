package benching

import (
	"fmt"
	"math"
	"math/rand/v2"
	"os"
	"strings"
	"testing"

	"github.com/rs/zerolog"

	"github.com/sirkon/blog"
	"github.com/sirkon/blog/beer"
)

var (
	binlog  *blog.Logger
	zlogger zerolog.Logger

	midMsg       = strings.Repeat("A", 64)
	noCtxPayload = [][2]string{
		{
			"short",
			strings.Repeat("A", 16),
		},
		{
			"mid",
			strings.Repeat("A", 64),
		},
		{
			"longer",
			strings.Repeat("A", 128),
		},
		{
			"long",
			strings.Repeat("A", 256),
		},
		{
			"escape",
			strings.Repeat(`abcdedf"`, 4),
		},
	}

	ctx3Payload = []logCtx3{}
)

func TestMain(t *testing.M) {
	beer.InsertLocationsOff()

	var files []*os.File
	defer func() {
		for _, file := range files {
			if err := file.Close(); err != nil {
				fmt.Println(beer.Wrap(err, "close "+file.Name()))
			}
		}
	}()

	binlog, _ = blog.NewLogger(newBufferWriter(), blog.OptionLogFromLevel(blog.LevelDebug))
	zlogger = zerolog.New(newBufferWriter())
	rnd := newRandom()

	for range 5 {
		ctx3Payload = append(ctx3Payload, logCtx3{
			Int:   rnd.randInt(),
			Count: rnd.poisson(21),
			Str:   strings.Repeat("A", rnd.poisson(10)),
		})
	}

	t.Run()
}

// --- Just message without a context -----------

func BenchmarkBinLog(b *testing.B) {
	for _, payload := range noCtxPayload {
		b.Run(payload[0], func(b *testing.B) {
			b.ReportAllocs()
			for b.Loop() {
				binlog.Error(nil, payload[1])
			}
		})
	}
}

func BenchmarkZeroLog(b *testing.B) {
	for _, payload := range noCtxPayload {
		b.Run(payload[0], func(b *testing.B) {
			b.ReportAllocs()
			for b.Loop() {
				zlogger.Error().Msg(payload[1])
			}
		})
	}
}

// --- Message + 3 context elements -----------

func BenchmarkBinLogCtx3(b *testing.B) {
	b.ReportAllocs()
	for b.Loop() {
		for _, p := range ctx3Payload {
			binlog.Error(nil,
				midMsg,
				blog.Int("int", p.Int),
				blog.Str("str", p.Str),
				blog.Int("count", p.Count),
			)
		}
	}
}

func BenchmarkZeroLogCtx3(b *testing.B) {
	b.ReportAllocs()
	for b.Loop() {
		for _, p := range ctx3Payload {
			zlogger.Error().
				Int("int", p.Int).
				Str("str", p.Str).
				Int("count", p.Count).
				Msg(midMsg)
		}
	}
}

// --------------------------------------------

type logCtx3 struct {
	Int   int
	Count int
	Str   string
}

type bufferWrite struct {
	buf []byte
}

func newBufferWriter() *bufferWrite {
	return &bufferWrite{
		buf: make([]byte, 16384),
	}
}

func (b *bufferWrite) Write(p []byte) (n int, err error) {
	copy(b.buf, p)
	return len(p), nil
}

type random struct {
	rand *rand.Rand
}

func newRandom() *random {
	res := &random{}
	res.reset()
	return res
}

func (r *random) reset() {
	r.rand = rand.New(rand.NewPCG(0, math.MaxUint64))
}

func (r *random) poisson(lambda float64) int {
	if lambda <= 0 {
		return 0
	}

	L := math.Exp(-lambda)
	k := 0
	p := 1.0

	for p > L {
		k++
		p *= r.rand.Float64()
	}

	return k - 1
}

func (r *random) randInt() int {
	return r.rand.Int()
}
