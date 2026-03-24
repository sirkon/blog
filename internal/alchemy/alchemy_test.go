package alchemy

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"fmt"
	"go/ast"
	"go/parser"
	"io"
	"math"
	"math/rand/v2"
	"os"
	"runtime/debug"
	"strconv"
	"strings"
	"testing"
	"time"
	"unsafe"

	"github.com/sirkon/blog"
	"github.com/sirkon/blog/beer"
	"github.com/sirkon/blog/internal/core"
)

var (
	msgActions = []string{"failed to", "successfully", "started", "finished", "retrying", "timeout during"}
	msgObjects = []string{"database connection", "http request", "user session", "cache lookup", "payload validation", "backend stream"}
	msgReasons = []string{"connection reset by peer", "context canceled", "invalid checksum", "auth token expired", "out of memory"}
	msgFields  = []string{"trace_id", "span_id", "node_id", "retry_count", "latency_ms"}

	keysClassic = []string{"id", "uid", "ip", "msg", "ts", "lv", "pid", "tid", "err", "ctx"}
	keyPrefixes = []string{"http", "db", "auth", "cache", "user", "sys", "internal", "remote"}
	keySubjets  = []string{"request", "connection", "session", "transaction", "payload", "error", "latency", "node"}
	keySuffixes = []string{"id", "ms", "count", "status", "type", "header", "body", "hash", "retry"}

	strTypicalVals = []string{"Hello World!", "/usr/bin/local/service", "ef67-1234-abcd", "found match"}
)

type LogGenerator struct {
	r     *rand.Rand
	data  []byte
	attrs []blog.Attr
}

func NewLogGenerator() *LogGenerator {
	return &LogGenerator{
		r:     rand.New(rand.NewPCG(1, 100_000_000)),
		data:  make([]byte, 0, 16384),
		attrs: make([]blog.Attr, 0, 128),
	}
}

func (g *LogGenerator) Reset() {
	g.data = g.data[:0]
	g.attrs = g.attrs[:0]
}

func (g *LogGenerator) Message() string {
	start := len(g.data)

	switch g.r.IntN(3) {
	case 0: // Типичный ворнинг/ошибка
		g.data = append(g.data, msgActions[g.r.IntN(len(msgActions))]...)
		g.data = append(g.data, ' ')
		g.data = append(g.data, msgObjects[g.r.IntN(len(msgObjects))]...)
		g.data = append(g.data, ':', ' ')
		g.data = append(g.data, msgReasons[g.r.IntN(len(msgReasons))]...)
		ptr := unsafe.Add(unsafe.Pointer(unsafe.SliceData(g.data)), uintptr(start))
		return unsafe.String((*byte)(ptr), len(g.data)-start)

	case 1: // Просто статус
		g.data = append(g.data, msgActions[g.r.IntN(len(msgActions))]...)
		g.data = append(g.data, " processing "...)
		g.data = append(g.data, msgObjects[g.r.IntN(len(msgObjects))]...)
		ptr := unsafe.Add(unsafe.Pointer(unsafe.SliceData(g.data)), uintptr(start))
		return unsafe.String((*byte)(ptr), len(g.data)-start)

	default: // Каша из полей
		g.data = append(g.data, "processed "...)
		g.data = append(g.data, msgObjects[g.r.IntN(len(msgObjects))]...)
		g.data = append(g.data, " with "...)
		g.data = append(g.data, msgFields[g.r.IntN(len(msgFields))]...)
		g.data = append(g.data, '=')
		g.data = strconv.AppendInt(g.data, int64(g.r.IntN(1000)), 10)
		ptr := unsafe.Add(unsafe.Pointer(unsafe.SliceData(g.data)), uintptr(start))
		return unsafe.String((*byte)(ptr), len(g.data)-start)
	}
}

func (g *LogGenerator) Attrs() []blog.Attr {
	g.generateAttrs()
	return g.attrs
}

func (g *LogGenerator) realisticInt() int {
	p := g.r.IntN(100)
	switch {
	case p < 35:
		return g.r.IntN(10) // 1 знак (0-9)
	case p < 55:
		return g.r.IntN(90) + 10 // 2 знака (10-99)
	case p < 70:
		return g.r.IntN(900) + 100 // 3 знака (100-999)
	case p < 78:
		return g.r.IntN(9000) + 1000 // 4 знака
	case p < 83:
		return g.r.IntN(90000) + 10000 // 5 знаков
	case p < 87:
		return g.r.IntN(900000) + 100000 // 6 знаков
	case p < 89:
		return g.r.IntN(9000000) + 1000000 // 7 знаков
	case p < 90:
		return g.r.IntN(90000000) + 10000000 // 8 знаков
	default:
		return int(time.Now().UnixNano()) // 19 знаков (Таймстамп)
	}
}

func (g *LogGenerator) randomAttr() {
	p := g.r.IntN(100)
	key := g.generateRandomKey()

	switch {
	case p < 45: // String (45%)
		g.attrs = append(g.attrs, blog.Str(key, strTypicalVals[g.r.IntN(len(strTypicalVals))]))

	case p < 80: // Int64 (35%)
		g.attrs = append(g.attrs, blog.Int(key, g.realisticInt()))

	case p < 90: // Bool (10%)
		g.attrs = append(g.attrs, blog.Bool(key, g.r.IntN(2) == 1))

	case p < 95: // Float64 (5%)
		g.attrs = append(g.attrs, blog.Flt64(key, g.r.Float64()*100.0))

	default: // Uint16/32 (5%)
		if g.r.IntN(2) == 0 {
			g.attrs = append(g.attrs, blog.Uint16(key, uint16(g.r.Uint32())))
			return
		}

		g.attrs = append(g.attrs, blog.Uint32(key, g.r.Uint32()))
	}
}

func (g *LogGenerator) generateAttrs() {
	p := g.r.IntN(100)

	var l int
	switch {
	case p < 40:
		l = g.r.IntN(4)
	case p < 85:
		l = g.r.IntN(5) + 4
	case p < 95:
		l = g.r.IntN(16) + 10
	default:
		l = g.r.IntN(10) + 25
	}

	for range l {
		g.randomAttr()
	}
}

func (g *LogGenerator) generateRandomKey() string {
	// 1. С вероятностью 30% выдаем "короткую классику"
	if g.r.IntN(10) < 3 {
		return keysClassic[g.r.IntN(len(keysClassic))]
	}

	sep := byte('_')
	if g.r.IntN(4) == 0 {
		sep = '-'
	}
	if g.r.IntN(10) == 0 {
		sep = '.'
	}

	// 2. С вероятностью 70% собираем "монстра"
	parts := g.r.IntN(3) + 1 // 1, 2 или 3 части
	start := len(g.data)

	g.data = append(g.data, keyPrefixes[g.r.IntN(len(keyPrefixes))]...)
	if parts > 1 {
		g.data = append(g.data, sep)
		g.data = append(g.data, keySubjets[g.r.IntN(len(keySubjets))]...)
	}

	if parts > 2 {
		g.data = append(g.data, sep)
		g.data = append(g.data, keySuffixes[g.r.IntN(len(keySuffixes))]...)
	}

	ptr := unsafe.Add(unsafe.Pointer(unsafe.SliceData(g.data)), uintptr(start))
	return unsafe.String((*byte)(ptr), len(g.data)-start)
}

func TestLargeFile(t *testing.T) {
	out, err := os.Create("large.bin")
	if err != nil {
		t.Fatal(beer.Wrap(err, "create large.bin"))
	}
	defer func() {
		if err := out.Close(); err != nil {
			t.Error(beer.Wrap(err, "close large.bin"))
		}
	}()
	buf := bufio.NewWriterSize(out, 2*1024*1024)
	defer func() {
		if err := buf.Flush(); err != nil {
			t.Error(beer.Wrap(err, "flush buffered writer"))
		}
	}()

	beer.InsertLocationsOff()
	log, err := blog.NewLogger(buf)
	if err != nil {
		t.Fatal(beer.Wrap(err, "create logger"))
	}
	g := NewLogGenerator()

	for range 10_000_000 {
		g.Reset()
		msg := g.Message()
		attrs := g.Attrs()

		p := g.r.IntN(100)
		switch {
		case p < 85:
			log.Info(nil, msg, attrs...)
		case p < 95:
			log.Debug(nil, msg, attrs...)
		case p < 98:
			log.Warn(nil, msg, attrs...)
		default:
			log.Error(nil, msg, attrs...)
		}
	}
}

func TestAlchemy(t *testing.T) {
	beer.InsertLocationsOn()

	type sample struct {
		name     string
		needLocs bool
		logger   func(log *blog.Logger)
	}

	samples := []sample{
		{
			name:     "message_only.bin",
			needLocs: true,
			logger: func(log *blog.Logger) {
				log.Info(nil, "just a message")
			},
		},
		{
			name:     "message_short_flat_context.bin",
			needLocs: true,
			logger: func(log *blog.Logger) {
				log.Info(nil, "a message with the short flat context",
					blog.Int("int", 4), blog.Str("string", "Hello World!"),
					blog.Flt64("pi", math.Pi),
				)
			},
		},
		{
			name:     "message_with_binary_in_ctx.bin",
			needLocs: false,
			logger: func(log *blog.Logger) {
				log.Info(nil, "a message with bytes field", blog.Bytes("data", []byte{1, 2, 3}))
			},
		},
		{
			name:     "message_with_loads_of_slices.bin",
			needLocs: false,
			logger: func(log *blog.Logger) {
				log.Info(nil, "a message with loads of slices",
					blog.Bools("bool", []bool{true, false, true, true, true, false}),
					blog.Ints("int", []int{math.MinInt, -1, math.MaxInt}),
					blog.Int8s("int8", []int8{math.MinInt8, -1, math.MaxInt8}),
					blog.Int16s("int16", []int16{math.MinInt16, -1, math.MaxInt16}),
					blog.Int32s("int32", []int32{math.MinInt32, -1, math.MaxInt32}),
					blog.Int64s("int64", []int64{math.MinInt64, -1, math.MaxInt64}),
					blog.Uints("uint", []uint{0, 1, math.MaxUint}),
					blog.Uint8s("uint8", []uint8{0, 1, math.MaxUint8}),
					blog.Uint16s("uint16", []uint16{0, 1, math.MaxUint16}),
					blog.Uint32s("uint32", []uint32{0, 1, math.MaxUint32}),
					blog.Uint64s("uint64", []uint64{0, 1, math.MaxUint64}),
					blog.Flt32s("float32", []float32{0.5, 0.75, math.SmallestNonzeroFloat32}),
					blog.Flt64s("float64", []float64{math.Pi, math.E, math.SmallestNonzeroFloat64, math.NaN()}),
					blog.Strs("string", []string{"Hello World!", "Hello Galaxy!", "Hello Universe!"}),
				)
			},
		},
		{
			name:     "group.bin",
			needLocs: false,
			logger: func(log *blog.Logger) {
				log.Info(nil, "a message and a group",
					blog.Group("empty"),
					blog.Group("group",
						blog.Int("int", 4),
						blog.Str("string", "Hello World!"),
					),
					blog.Group("outer",
						blog.Group("inner",
							blog.Int("int1", 5),
							blog.Str("string1", "I'm here"),
						),
						blog.Int("int", 4),
					),
				)
			},
		},
		{
			name:     "errors.bin",
			needLocs: false,
			logger: func(log *blog.Logger) {
				errBeer := beer.New("error").Str("new-string", "Hello World!")
				errBeer = beer.Wrap(errBeer, "wrap").Int("wrap-int", 1)
				errBeer = beer.Just(errBeer).Flt64("just-pi", math.Pi)

				errTip := beer.Wrap(io.EOF, "wrap foreign").Bool("wrap-bool", true)

				var errIntmixed error = beer.New("error").Time("new-time", time.Now())
				errIntmixed = fmt.Errorf("foreign wrap: %w", errIntmixed)

				log.Error(nil, "errors",
					blog.Error("err-foreign", io.EOF),
					blog.Error("err-beer", errBeer),
					blog.Error("err-foreign-root", errTip),
					blog.Error("err-intermixed", errIntmixed),
				)
			},
		},
		{
			name:     "error_intmixed.bin",
			needLocs: false,
			logger: func(log *blog.Logger) {
				var err error = beer.New("error").Str("string", "Hello World!")
				err = fmt.Errorf("foreign wrap: %w", err)
				log.Error(nil, "errors", blog.Err(err))
			},
		},
		{
			name:     "error_foreign_root.bin",
			needLocs: false,
			logger: func(log *blog.Logger) {
				err := beer.Wrap(io.EOF, "wrap").Int("wrap-int", 1)
				log.Error(nil, "errors", blog.Err(err))
			},
		},
		{
			name:     "panic.bin",
			needLocs: false,
			logger: func(log *blog.Logger) {
				defer func() {
					r := recover()
					if r == nil {
						return
					}
					info := blog.LogPanicInfo(r)
					blog.LogPanic(context.Background(), log, debug.Stack(), info)
				}()

				panic("this is a panic")
			},
		},
	}
	for i, s := range samples {
		if err := validateSampleName(s.name); err != nil {
			t.Errorf("sample #%d %q must have <identifier>.bin form: %s", i, s.name, err)
			continue
		}

		t.Run(s.name, func(tt *testing.T) {
			var buf bytes.Buffer
			var opts []core.OptionApplier
			if s.needLocs {
				opts = append(
					opts,
					core.OptionLogLocations(),
				)
			}
			w := io.MultiWriter(&buf, blog.NewPrettyWriter(os.Stdout).WithLightTerminal())
			logger, err := blog.NewLogger(w, opts...)
			if err != nil {
				t.Errorf("failed to create logger: %s", err)
				return
			}

			s.logger(logger)
			if err := os.WriteFile(s.name, buf.Bytes(), 0644); err != nil {
				t.Errorf("failed to write file: %s", err)
			}
		})
	}
}

func validateSampleName(name string) error {
	if name == "" {
		return errors.New("got empty name")
	}

	if !strings.HasSuffix(name, ".bin") {
		return errors.New("name must end with .bin")
	}

	n := strings.TrimSuffix(name, ".bin")
	expr, err := parser.ParseExpr(n)
	if err != nil {
		return fmt.Errorf("check if ext-less name represents correct Go expression: %w", err)
	}

	switch expr.(type) {
	case *ast.Ident:
		return nil
	default:
		return fmt.Errorf("sample name without an extension must be correct Go identifier")
	}
}
