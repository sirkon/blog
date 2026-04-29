package main

import (
	"os"
	"strconv"
	"strings"

	"github.com/sirkon/errors"
	"github.com/sirkon/gogh"
	"github.com/sirkon/message"
)

func main() {
	if err := generate(); err != nil {
		message.Fatal(err)
	}
}

func generate() error {
	if err := os.Chdir("../../.."); err != nil {
		return errors.Wrap(err, "chdir to blog root")
	}

	prj, err := gogh.New[*gogh.Imports](gogh.GoFmt, func(r *gogh.Imports) *gogh.Imports {
		return r
	})
	if err != nil {
		return errors.Wrap(err, "init module generator")
	}

	root, err := prj.Package("alchemy", "internal/alchemy")
	if err != nil {
		return errors.Wrap(err, "dive into internal/alchemy")
	}

	r := root.Go("alchemy.go", gogh.Autogen("internalgen"))

	g := NewLogGenerator()

	r.Imports().Add("github.com/sirkon/blog").Ref("blog")
	r.L(`func logThings(@log *$blog.Logger) {`)
	r.N()
	for range 10_000 {
		g.Reset()
		attrs := g.Attrs()
		msg := g.Message()

		var buf strings.Builder
		for _, attr := range attrs {
			buf.WriteString(", ")
			var value any
			switch attr.kind {
			case attrTypeKindString:
				value = strconv.Quote(attr.value.String())
			case attrTypeKindInt:
				value = attr.value.Int64()
			case attrTypeKindBool:
				value = attr.value.Bool()
			case attrTypeKindFloat:
				value = attr.value.Float64()
			case attrTypeKindUint16:
				value = attr.value.Uint64()
			case attrTypeKindUint32:
				value = attr.value.Uint64()
			}
			buf.WriteString(r.S(`$blog.$0("$1", $2)`, attr.kind.String(), attr.name, value))
		}

		p := g.r.IntN(100)
		switch {
		case p < 85:
			r.L(`$log.Info(nil, "$0" $1)`, msg, buf.String())
		case p < 95:
			r.L(`$log.Debug(nil, "$0" $1)`, msg, buf.String())
		case p < 98:
			r.L(`$log.Warn(nil, "$0" $1)`, msg, buf.String())
		default:
			r.L(`$log.Error(nil, "$0" $1)`, msg, buf.String())
		}
	}

	r.L(`}`)

	if err := prj.Render(); err != nil {
		return errors.Wrap(err, "render generated code")
	}

	return nil
}
