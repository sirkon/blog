package blog_test

import (
	"fmt"
	"io"
	"log/slog"
	"math"
	"os"
	"path/filepath"
	"testing"

	"github.com/sirkon/blog"
	"github.com/sirkon/blog/beer"
)

var (
	binlog        *blog.Logger
	txtCtxLogger  *slog.Logger
	discardLogger *blog.Logger

	blogFile   *os.File
	txtCtxFile *os.File
)

func TestMain(t *testing.M) {
	var files []*os.File
	defer func() {
		for _, file := range files {
			if err := file.Close(); err != nil {
				fmt.Println(beer.Wrap(err, "close "+file.Name()))
			}
		}
	}()
	blogFile = createFile("beer.bin")
	files = append(files, blogFile)
	txtCtxFile = createFile("errors_txt.log")
	files = append(files, txtCtxFile)

	binlog, _ = blog.NewLogger(blog.NewSyncWriter(blogFile), blog.OptionLogFromLevel(blog.LevelDebug))
	txtCtxLogger = slog.New(slog.NewJSONHandler(txtCtxFile, &slog.HandlerOptions{}))
	discardLogger, _ = blog.NewLogger(blog.NewSyncWriter(io.Discard))

	t.Run()
}

func BenchmarkBlog(b *testing.B) {
	for b.Loop() {
		err := beer.New("this is an error").
			Bytes("bytes", []byte{1, 2, 3}).
			Str("text-bytes", "Hello World!")
		err = beer.Wrap(err, "check error").
			Int("count", 333).
			Bool("is-wrap-layer", true)
		err = beer.Just(err).
			Flt64("pi", math.Pi).
			Flt64("e", math.E)

		binlog.Error(nil, "failed to do something", blog.Err(err))
	}
}

func BenchmarkTxtContext(b *testing.B) {
	for b.Loop() {
		err := fmt.Errorf("this is an error bytes[%v] text-bytes[%s]", []byte{1, 2, 3}, "Hello World!")
		err = fmt.Errorf("check error count[%d] is-wrap-layer[%v]: %w", 333, true, err)
		err = fmt.Errorf("context pi[%g] e[%g]: %w", math.Pi, math.E, err)

		txtCtxLogger.Error("failed to do something", slog.Any("err", err))
	}
}

func BenchmarkAssembleAndFormattingCost(b *testing.B) {
	for b.Loop() {
		err := beer.New("this is an error").
			Bytes("bytes", []byte{1, 2, 3}).
			Str("text-bytes", "Hello World!")
		err = beer.Wrap(err, "check error").
			Int("count", 333).
			Bool("is-wrap-layer", true)
		err = beer.Just(err).
			Flt64("pi", math.Pi).
			Flt64("e", math.E)

		discardLogger.Error(nil, "failed to do something", blog.Err(err))
	}
	blog.NewLogger(blog.NewSyncWriter(blogFile))
}

func TestLogSize(t *testing.T) {
	{
		err := beer.New("this is an error").
			Bytes("bytes", []byte{1, 2, 3}).
			Str("text-bytes", "Hello World!")
		err = beer.Wrap(err, "check error").
			Int("count", 333).
			Bool("is-wrap-layer", true)
		err = beer.Just(err).
			Flt64("pi", math.Pi).
			Flt64("e", math.E)

		bsize := &loggerSizeComputer{}
		binlog, _ := blog.NewLogger(bsize)
		binlog.Error(nil, "failed to do something", blog.Err(err))
		t.Log("blog size:", bsize.size)
	}

	{
		ssize := &loggerSizeComputer{}
		sslog := slog.New(slog.NewJSONHandler(ssize, &slog.HandlerOptions{}))
		err := fmt.Errorf("this is an error bytes[%v] text-bytes[%s]", []byte{1, 2, 3}, "Hello World!")
		err = fmt.Errorf("check error count[%d] is-wrap-layer[%v]: %w", 333, true, err)
		err = fmt.Errorf("context pi[%g] e[%g]: %w", math.Pi, math.E, err)

		sslog.Error("failed to do something", slog.Any("err", err))
		t.Log("text context size:", ssize.size)
	}
}

func BenchmarkAssembleCost(b *testing.B) {
	for b.Loop() {
		err := beer.New("this is an error").
			Bytes("bytes", []byte{1, 2, 3}).
			Str("text-bytes", "Hello World!")
		err = beer.Wrap(err, "check error").
			Int("count", 333).
			Bool("is-wrap-layer", true)
		err = beer.Just(err).
			Flt64("pi", math.Pi).
			Flt64("e", math.E)

		if err == nil {
			panic("must not be nil")
		}
	}
}

func createFile(name string) *os.File {
	file, err := os.Create(filepath.Join(name))
	if err != nil {
		panic(beer.Wrap(err, "create file "+name))
	}

	return file
}

type loggerSizeComputer struct {
	size int
}

func (l *loggerSizeComputer) Write(p []byte) (n int, err error) {
	l.size += len(p)
	return len(p), nil
}
