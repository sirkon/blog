package blog_test

import (
	"bytes"
	"errors"
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
	blogpLogger   *blog.Logger
	bufferLogger  *blog.Logger

	blogFile           *os.File
	blogTextPrettyFile *os.File
	txtCtxFile         *os.File
	justFile           *os.File
	zlogFile           *os.File

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
	blogFile = createFile("beer.bin")
	files = append(files, blogFile)
	txtCtxFile = createFile("errors_txt.log")
	files = append(files, txtCtxFile)
	justFile = createFile("just.log")
	files = append(files, justFile)
	blogTextPrettyFile = createFile("blogpretty.log")
	files = append(files, blogTextPrettyFile)
	zlogFile = createFile("zlog.log")
	files = append(files, zlogFile)

	binlog, _ = blog.NewLogger(blog.NewSyncWriter(blogFile), blog.OptionLogFromLevel(blog.LevelDebug))
	txtCtxLogger = slog.New(slog.NewJSONHandler(txtCtxFile, &slog.HandlerOptions{}))
	discardLogger, _ = blog.NewLogger(blog.NewSyncWriter(io.Discard))
	blogpLogger, _ = blog.NewLogger(blog.NewPrettyWriter(blogTextPrettyFile))
	bufferLogger, _ = blog.NewLogger(newBufferWriter())

	t.Run()
}

func BenchmarkBlog(b *testing.B) {
	b.ReportAllocs()
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
	b.ReportAllocs()
	for b.Loop() {
		err := fmt.Errorf("this is an error bytes[%v] text-bytes[%s]", []byte{1, 2, 3}, "Hello World!")
		err = fmt.Errorf("check error count[%d] is-wrap-layer[%v]: %w", 333, true, err)
		err = fmt.Errorf("context pi[%g] e[%g]: %w", math.Pi, math.E, err)

		txtCtxLogger.Error("failed to do something", slog.Any("err", err))
	}
}

func BenchmarkTxtNoContext(b *testing.B) {
	b.ReportAllocs()
	for b.Loop() {
		err := fmt.Errorf("this is an error")
		err = fmt.Errorf("check error: %w", err)
		err = fmt.Errorf("context: %w", err)

		txtCtxLogger.Error("failed to do something", slog.Any("err", err))
	}
}

func BenchmarkBlogTxtContext(b *testing.B) {
	b.ReportAllocs()
	for b.Loop() {
		err := fmt.Errorf("this is an error bytes[%v] text-bytes[%s]", []byte{1, 2, 3}, "Hello World!")
		err = fmt.Errorf("check error count[%d] is-wrap-layer[%v]: %w", 333, true, err)
		err = fmt.Errorf("context pi[%g] e[%g]: %w", math.Pi, math.E, err)

		binlog.Error(nil, "failed to do something", blog.Err(err))
	}
}

func BenchmarkBlogTxtNoContext(b *testing.B) {
	b.ReportAllocs()
	for b.Loop() {
		err := fmt.Errorf("this is an error")
		err = fmt.Errorf("check error: %w", err)
		err = fmt.Errorf("context: %w", err)

		binlog.Error(nil, "failed to do something", blog.Err(err))
	}
}

func BenchmarkBufferWriteCost(b *testing.B) {
	b.Run("beer", func(b *testing.B) {
		b.ReportAllocs()
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
			bufferLogger.Error(nil, "failed to do something", blog.Err(err))
		}
	})

	b.Run("txt-no-context", func(b *testing.B) {
		b.ReportAllocs()
		for b.Loop() {
			err := fmt.Errorf("this is an error")
			err = fmt.Errorf("check error: %w", err)
			err = fmt.Errorf("context: %w", err)

			bufferLogger.Error(nil, "failed to do something", blog.Err(err))
		}
	})
}

func BenchmarkWriteCost(b *testing.B) {
	for b.Loop() {
		if _, err := justFile.Write(text); err != nil {
			b.Fatal(err)
		}
	}
}

func TestLogSize(t *testing.T) {
	t.Run("binary log size", func(t *testing.T) {
		err := beer.New("this is an error").
			Bytes("bytes", []byte{1, 2, 3}).
			Str("text-bytes", "Hello World!")
		err = beer.Wrap(err, "check error").
			Int("count", 333).
			Bool("is-wrap-layer", true)
		err = beer.Just(err).
			Flt64("pi", math.Pi).
			Flt64("e", math.E)

		bsize := loggerSizeComputer("binary log with beer.Error")
		binlog, _ := blog.NewLogger(bsize)
		binlog.Error(nil, "failed to do something", blog.Err(err))
	})

	t.Run("txt log size", func(t *testing.T) {
		ssize := loggerSizeComputer("slog with text context")
		sslog := slog.New(slog.NewJSONHandler(ssize, &slog.HandlerOptions{}))
		err := fmt.Errorf("this is an error bytes[%v] text-bytes[%s]", []byte{1, 2, 3}, "Hello World!")
		err = fmt.Errorf("check error count[%d] is-wrap-layer[%v]: %w", 333, true, err)
		err = fmt.Errorf("context pi[%g] e[%g]: %w", math.Pi, math.E, err)

		sslog.Error("failed to do something", slog.Any("err", err))
	})

	t.Run("check wrap strategies sizes", func(t *testing.T) {

		t.Run("pure beer", func(t *testing.T) {
			binlog, _ := blog.NewLogger(loggerSizeComputer("pure beer.Error"))
			err := beer.New("error")
			err = beer.Wrap(err, "wrap 1")
			err = beer.Wrap(err, "wrap 2")
			binlog.Debug(nil, "log", blog.Err(err))
		})

		t.Run("foreign on the nip", func(t *testing.T) {
			binlog, _ := blog.NewLogger(loggerSizeComputer("beer.Error with foreign error on the tip"))
			err := errors.New("error")
			err = beer.Wrap(err, "wrap 1")
			err = beer.Wrap(err, "wrap 2")
			binlog.Debug(nil, "log", blog.Err(err))
		})

		t.Run("foreign wrap", func(t *testing.T) {
			binlog, _ := blog.NewLogger(loggerSizeComputer("beer.Error and foreign error intermixed"))
			var err error = beer.New("error")
			err = beer.Wrap(err, "wrap 1")
			err = fmt.Errorf("wrap 2: %w", err)
			binlog.Debug(nil, "log", blog.Err(err))
		})
	})
}

func createFile(name string) *os.File {
	file, err := os.Create(filepath.Join(os.TempDir(), name))
	if err != nil {
		panic(beer.Wrap(err, "create file "+name))
	}

	return file
}

type loggerSizeComputer string

func (l loggerSizeComputer) Write(p []byte) (n int, err error) {
	fmt.Println(string(l), "write size:", len(p))
	return len(p), nil
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
