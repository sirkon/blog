package benching

import (
	"encoding/json"
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
	zlogger = zerolog.New(newBufferWriter()).With().Timestamp().Logger()
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

// --- Worst case for binlog --------

func BenchmarkWorstCaseForBlog(b *testing.B) {
	b.Run("BinLog", func(b *testing.B) {
		b.ReportAllocs()
		for b.Loop() {
			binlog.Error(
				nil,
				"test",
				blog.Int("i1", 1), blog.Str("t1", "1"),
				blog.Int("i2", 2), blog.Str("t2", "2"),
				blog.Int("i3", 3), blog.Str("t3", "3"),
				blog.Int("i4", 4), blog.Str("t4", "4"),
				blog.Int("i5", math.MaxInt), blog.Str("t5", "5"),
			)
		}
	})

	b.Run("ZeroLog", func(b *testing.B) {
		b.ReportAllocs()
		for b.Loop() {
			zlogger.Error().
				Int("i1", 1).Str("t1", "1").
				Int("i2", 2).Str("t2", "2").
				Int("i3", 3).Str("t3", "3").
				Int("i4", 4).Str("t4", "4").
				Int("i5", math.MaxInt).Str("t5", "5").
				Msg("test")
		}
	})
}

// --- Real log sample ---------

func BenchmarkRealLog(b *testing.B) {
	// Sample to produce {
	// 	"level":"info",       // These two will not be set up obviously
	// 	"ts":1710708422.123,  //
	// 	"caller":"auth/service.go:42",
	// 	"msg":"User logged in",
	// 	"user_id":"u-9912",
	// 	"ip_address":"192.168.1.15"
	// }

	b.Run("BinLog", func(b *testing.B) {
		b.ReportAllocs()
		for b.Loop() {
			binlog.Info(nil, "User logged in",
				blog.Str("user-id", "u-9912"),
				blog.Str("ip_address", "192.168.1.15"),
			)
		}
	})

	b.Run("ZeroLog", func(b *testing.B) {
		b.ReportAllocs()
		for b.Loop() {
			zlogger.Info().
				Str("user-id", "u-9912").
				Str("ip_address", "192.168.1.15").
				Msg("User logged in")
		}
	})
}

func BenchmarkRealErrorLog(b *testing.B) {
	b.Run("BinLog", func(b *testing.B) {
		b.ReportAllocs()
		for b.Loop() {
			err := beer.New("failed to commit stream").
				Str("user-role", "COMMON-USER").
				Str("method", "service.Method").
				Str("response-code", "NOT_AUTHORIZED")
			err = beer.Wrap(err, "stream data under service user").
				Strs("documents", []string{"document1", "document2"}).
				Str("document-class", "application/text")
			err = beer.Wrap(err, "merge documents").
				Ints("documents", []int{100000000001, 200002123123})
			binlog.Error(nil, "failed to merge documents", blog.Err(err))
		}
	})

	b.Run("ZeroLog", func(b *testing.B) {
		b.ReportAllocs()
		for b.Loop() {
			err := fmt.Errorf("failed to commit stream user-role[%s] method[%s] response-code[%s]",
				"COMMON-USER", "service.Method", "NOT_AUTHORIZED",
			)
			err = fmt.Errorf("stream data under service user documents[%v] document-class[%s]: %w",
				[]string{"document1", "document2"}, "application/text", err)
			err = fmt.Errorf("merge documents documents[%v] document-class[%s]: %w",
				[]int{100000000001, 200002123123}, "application/text", err)
			zlogger.Error().Err(err).Msg("failed to merge documents")
		}
	})
}

// --- Message + 3 context elements -----------

func BenchmarkBinLogCtx3(b *testing.B) {
	b.ReportAllocs()
	data, _ := json.MarshalIndent(ctx3Payload, "", "  ")
	b.Log(string(data))
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
