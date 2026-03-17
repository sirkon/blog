package benching

import (
	"bytes"
	"fmt"
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

	text = bytes.Repeat([]byte{0}, 256)
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

	t.Run()
}

// --- Just message without a context -----------

var noCtxPayload = [][2]string{
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
}

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
