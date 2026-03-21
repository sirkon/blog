package alchemy

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"go/ast"
	"go/parser"
	"io"
	"math"
	"os"
	"runtime/debug"
	"strings"
	"testing"
	"time"

	"github.com/sirkon/blog"
	"github.com/sirkon/blog/beer"
	"github.com/sirkon/blog/internal/core"
)

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
