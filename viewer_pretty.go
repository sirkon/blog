package blog

import (
	"bufio"
	"bytes"
	"compress/gzip"
	"fmt"
	"go/token"
	"io"
	"os"
	"strconv"
	"sync"
	"unsafe"

	"github.com/sirkon/blog/internal/core"
)

type PrettyWriter struct {
	lock sync.Mutex

	w         io.Writer
	view      *packedDeconstruct
	buf       []byte
	stack     []int
	branch    []bool
	colorBack string
	colorProf *prettyWriterColorProfile
}

func NewPrettyWriter(w io.Writer) *PrettyWriter {
	tree := &packedTree{
		ctrl: make([]byte, prettyViewNodeSize*128),
		data: make([]byte, 0, 2048),
	}
	ctx := &packedContextDeconstruct{
		tree: tree,
	}
	return &PrettyWriter{
		w: w,
		view: &packedDeconstruct{
			tree: tree,
			ctx:  ctx,
		},
		colorProf: &prettyWriterColorProfile{}, // no ANSI colors by default
	}
}

func (g *PrettyWriter) WithDarkTerminal() *PrettyWriter {
	g.colorProf = newPrettyWriterColorProfileDark()
	return g
}

func (g *PrettyWriter) WithLightTerminal() *PrettyWriter {
	g.colorProf = newPrettyWriterColorProfileLight()
	return g
}

func (g *PrettyWriter) Write(p []byte) (n int, err error) {
	g.lock.Lock()
	defer g.lock.Unlock()

	g.view.loc = token.Position{}
	g.view.tree.Reset()
	g.view.ctx.Reset()
	g.buf = g.buf[:0]
	g.stack = g.stack[:0]

	if err := core.ProcessRecord(p, g.view); err != nil {
		return 0, core.WrapError(err, "process record")
	}

	// TODO добавить ANSI-кодов для цвета и прочего
	g.formatTime()
	g.buf = append(g.buf, ' ')
	g.formatLevel()
	g.buf = append(g.buf, ' ')
	if g.view.loc.IsValid() {
		g.formatLocation()
		g.buf = append(g.buf, ' ')
	}

	if g.view.level != core.LoggingLevelPanic {
		g.colorBold()
		g.buf = append(g.buf, g.view.msg...)
		g.buf = append(g.buf, ' ', ' ')
		g.colorReset()

		g.setBackCtx()
		// TODO добавить ANSI для контекста
		if len(g.view.ctx.errors) == 0 {
			g.walkJSON()
		} else {
			g.buf = append(g.buf, '\n')
			g.walkTree()
		}
	} else {
		g.walkJSON()

		reader, err := gzip.NewReader(bytes.NewReader(g.view.msg))
		if err != nil {
			g.colorSTDots()
			g.buf = append(g.buf, '.', '.', '.', '.')
			g.colorSTText()
			g.buf = append(g.buf, err.Error()...)
			g.buf = append(g.buf, '\n')
			g.colorReset()
		} else {
			scanner := bufio.NewScanner(reader)
			for scanner.Scan() {
				g.colorSTDots()
				g.buf = append(g.buf, '.', '.', '.', '.', ' ')
				g.colorSTText()
				g.buf = append(g.buf, scanner.Bytes()...)
				g.buf = append(g.buf, '\n')
				g.colorReset()
			}
		}
	}
	g.setBackTxt()

	if _, err := g.w.Write(g.buf); err != nil {
		_, _ = fmt.Fprintln(os.Stderr, "failed to write buffer:", err)
	}

	return len(p), nil
}

func (g *PrettyWriter) browseCtrl() {
	clen := g.view.tree.clen
	var pos int
	for pos < clen {
		node := (*prettyViewNode)(unsafe.Add(unsafe.Pointer(unsafe.SliceData(g.view.tree.ctrl)), pos))
		fmt.Printf("%03x %q -> kind[%s] next[%03x] misc[%03x]\n", pos, g.view.tree.unpackKey(node), node.kind&0x1F, node.next, node.misc)
		pos += prettyViewNodeSize
	}
}

func (g *PrettyWriter) formatTime() {
	g.colorTime()
	t := g.view.time
	g.buf = strconv.AppendInt(g.buf, int64(t.Year()), 10)
	g.buf = append(g.buf, '-')
	if t.Month() < 10 {
		g.buf = append(g.buf, '0')
	}
	g.buf = strconv.AppendInt(g.buf, int64(t.Month()), 10)
	g.buf = append(g.buf, '-')
	if t.Day() < 10 {
		g.buf = append(g.buf, '0')
	}
	g.buf = strconv.AppendInt(g.buf, int64(t.Day()), 10)
	g.buf = append(g.buf, ' ')
	if t.Hour() < 10 {
		g.buf = append(g.buf, '0')
	}
	g.buf = strconv.AppendInt(g.buf, int64(t.Hour()), 10)
	g.buf = append(g.buf, ':')
	if t.Minute() < 10 {
		g.buf = append(g.buf, '0')
	}
	g.buf = strconv.AppendInt(g.buf, int64(t.Minute()), 10)
	g.buf = append(g.buf, ':')
	if t.Second() < 10 {
		g.buf = append(g.buf, '0')
	}
	g.buf = strconv.AppendInt(g.buf, int64(t.Second()), 10)
	g.buf = append(g.buf, '.')
	ms := (t.Nanosecond() / 1_000_000) % 1_000
	if ms < 100 {
		if ms < 10 {
			g.buf = append(g.buf, '0')
		}
		g.buf = append(g.buf, ' ')
	}
	g.buf = strconv.AppendInt(g.buf, int64(ms), 10)
	g.colorReset()
}

func (g *PrettyWriter) formatLevel() {
	// TODO добавить ANSI
	switch g.view.level {
	case LevelTrace:
		g.colorLevelTrace()
		g.buf = append(g.buf, "TRACE"...)
		g.colorReset()
	case LevelDebug:
		g.colorLevelDebug()
		g.buf = append(g.buf, "DEBUG"...)
		g.colorReset()
	case LevelInfo:
		g.colorLevelInfo()
		g.buf = append(g.buf, "INFO "...)
		g.colorReset()
	case LevelWarning:
		g.colorLevelWarn()
		g.buf = append(g.buf, "WARN "...)
		g.colorReset()
	case LevelError:
		g.colorLevelError()
		g.buf = append(g.buf, "ERROR"...)
		g.colorReset()
	case core.LoggingLevelPanic:
		g.colorLevelPanic()
		g.buf = append(g.buf, "PANIC"...)
		g.colorReset()
	default:
		g.buf = append(g.buf, "UNKWN"...)
	}
}

func (g *PrettyWriter) formatLocation() {
	// TODO добавить ANSI
	loc := g.view.loc
	g.colorLocation()
	g.buf = append(g.buf, loc.Filename...)
	g.buf = append(g.buf, ':')
	g.buf = strconv.AppendInt(g.buf, int64(loc.Line), 10)
	g.colorReset()
}

var (
	newline = []byte("\n")
)
