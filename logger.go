package blog

import (
	"context"

	"github.com/sirkon/blog/internal/core"
)

type Logger = core.Logger

// NewLogger creates a new logger writing into the given WriteSyncer.
func NewLogger(w core.WriteSyncer, options ...core.OptionApplier) (*Logger, error) {
	return core.NewLogger(w, options...)
}

// LogPanic logs given stack trace at the Panic logging level.
// Is to be used withing panic recovery routines, something like:
//
//	defer func() {
//	    r := recover()
//	    if r == nil {
//	        return
//	    }
//	    info := blog.LogPanicInfo(r)
//	    blog.LogPanic(ctx, logger, debug.Stack(), info)
//	}()
//
// Panic text payload will be stored in gzipped form as a message.
func LogPanic(ctx context.Context, log *Logger, stacktrace []byte, info Attr) {
	core.LogPanic(ctx, log, stacktrace, info)
}

// LogPanicInfo extract panic "recovered" core in as meaningful form as possible.
// Should be used within recovery procedures, see at [LogPanic] for usage example.
func LogPanicInfo(v any) Attr {
	return core.LogPanicInfo(v)
}

// OptionLogLocations logger will show locations of logging.
func OptionLogLocations() core.OptionApplier {
	return OptionLogLocations()
}

func OptionLogFromLevel(l core.LoggingLevel) core.OptionApplier {
	return OptionLogFromLevel(l)
}

const (
	LevelTrace   = core.LoggingLevelTrace
	LevelDebug   = core.LoggingLevelDebug
	LevelInfo    = core.LoggingLevelInfo
	LevelWarning = core.LoggingLevelWarning
	LevelError   = core.LoggingLevelError
)
