package blog

import (
	"fmt"
)

// OptionHandler is implemented by functional options.
type OptionHandler interface {
	handle(l *Logger) error
}

// OptionLogLocations logger will show locations of logging.
func OptionLogLocations() OptionHandler {
	return &optionLogLocations{}
}

// OptionLogFromLevel logger will only log events with level starting from the given l.
func OptionLogFromLevel(l LoggingLevel) OptionHandler {
	return &optionLogFrom{
		l: l,
	}
}

type optionLogLocations struct{}

func (e *optionLogLocations) handle(l *Logger) error {
	l.logLocations = true
	return nil
}

type optionLogFrom struct {
	l LoggingLevel
}

func (e *optionLogFrom) handle(l *Logger) error {
	switch e.l {
	case LoggingLevelTrace:
	case LoggingLevelDebug:
	case LoggingLevelInfo:
	case LoggingLevelWarning:
	case LoggingLevelError:
	default:
		return fmt.Errorf("invalid-logging-level[%d]", e.l)
	}

	l.logFrom = e.l
	return nil
}
