package blog

type prettyWriterColorProfile struct {
	reset  string
	bold   string
	time   string
	trace  string
	debug  string
	info   string
	warn   string
	error  string
	panic  string
	loc    string // Color of locations for log itself and @location of error
	link   string // Hierarchy links of tree.
	stdots string
	sttext string
	key    string
	errkey string
	ctx    string
}

func newPrettyWriterColorProfileDark() *prettyWriterColorProfile {
	return &prettyWriterColorProfile{
		reset: "\033[0m",
		bold:  "\033[1m",

		time: "\033[35m", // magenta

		trace: "\033[90m", // dim gray
		debug: "\033[36m", // cyan
		info:  "\033[32m", // green
		warn:  "\033[33m", // yellow/orange
		error: "\033[31m", // red

		panic: "\033[1;41;97m",

		loc:  "\033[38;5;244m",
		link: "\033[38;5;240m",

		stdots: "\033[38;5;236m",
		sttext: "\033[38;5;245m",
		key:    "\033[38;5;109m",
		errkey: "\033[38;5;203m",
		ctx:    "\033[38;5;252m",
	}
}

func newPrettyWriterColorProfileLight() *prettyWriterColorProfile {
	return &prettyWriterColorProfile{
		reset: "\033[0m",
		bold:  "\033[1m",

		time: "\033[95m", // bright magenta

		trace: "\033[90m", // gray
		debug: "\033[36m", // cyan
		info:  "\033[32m", // green
		warn:  "\033[33m", // yellow/orange
		error: "\033[31m", // red

		panic: "\033[1;41;97m",

		loc:  "\033[38;5;240m",
		link: "\033[38;5;248m",

		stdots: "\033[38;5;252m",
		sttext: "\033[38;5;240m",
		key:    "\033[38;5;31m",
		errkey: "\033[38;5;203m",
		ctx:    "\033[38;5;238m",
	}
}
func (g *PrettyWriter) colorReset() {
	if g.colorBack == "" {
		g.buf = append(g.buf, g.colorProf.reset...)
		return
	}

	g.buf = append(g.buf, g.colorBack...)
}

func (g *PrettyWriter) setBackCtx() {
	g.colorBack = g.colorProf.ctx
	g.buf = append(g.buf, g.colorProf.ctx...)
}

func (g *PrettyWriter) setBackTxt() {
	g.colorBack = ""
	g.buf = append(g.buf, g.colorProf.reset...)
}

func (g *PrettyWriter) colorSetBack(back string) {
	g.colorBack = back
	g.buf = append(g.buf, back...)
}

func (g *PrettyWriter) colorBold() {
	g.buf = append(g.buf, g.colorProf.bold...)
}

func (g *PrettyWriter) colorLevelTrace() {
	g.buf = append(g.buf, g.colorProf.trace...)
}

func (g *PrettyWriter) colorLevelDebug() {
	g.buf = append(g.buf, g.colorProf.debug...)
}

func (g *PrettyWriter) colorLevelInfo() {
	g.buf = append(g.buf, g.colorProf.info...)
}

func (g *PrettyWriter) colorLevelWarn() {
	g.buf = append(g.buf, g.colorProf.warn...)
}

func (g *PrettyWriter) colorLevelError() {
	g.buf = append(g.buf, g.colorProf.error...)
}

func (g *PrettyWriter) colorLevelPanic() {
	g.buf = append(g.buf, g.colorProf.panic...)
}

func (g *PrettyWriter) colorLocation() {
	g.buf = append(g.buf, g.colorProf.loc...)
}

func (g *PrettyWriter) colorTime() {
	g.buf = append(g.buf, g.colorProf.time...)
}

func (g *PrettyWriter) colorLink() {
	g.buf = append(g.buf, g.colorProf.link...)
}

func (g *PrettyWriter) colorSTDots() {
	g.buf = append(g.buf, g.colorProf.stdots...)
}

func (g *PrettyWriter) colorSTText() {
	g.buf = append(g.buf, g.colorProf.sttext...)
}

func (g *PrettyWriter) colorKey() {
	g.buf = append(g.buf, g.colorProf.key...)
}

func (g *PrettyWriter) colorErrKey() {
	g.buf = append(g.buf, g.colorProf.errkey...)
}
